// SPDX-License-Identifier: EPL-2.0
//! Minimal nREPL server for `cljw nrepl` — F142 re-introduction per
//! ADR-0015 amendment 2 + ADR-0048 (state machine domain ADR;
//! nREPL chart filled at row 14.10).
//!
//! Single-thread runtime today → **single concurrent session**.
//! The accept loop is sequential: handle one session to completion
//! (`close` op or client disconnect), then loop back to accept the
//! next connection. Multi-session / `interrupt` op ride Phase B
//! (D-117). nREPL clients (CIDER / `lein nrepl-client`) connect
//! one at a time today; reconnect-after-disconnect works.
//!
//! Protocol surface (4 ops):
//! - `clone`           — issues a new session id; required by every
//!                       nREPL client at handshake.
//! - `describe`        — returns versions + supported-ops dict so the
//!                       client knows what's available.
//! - `eval`            — runs `code` (string) through the cw v1
//!                       analyzer/eval; emits one `value` response
//!                       per top-level form + a final
//!                       `status: ["done"]` response.
//! - `close`           — ends the session; client typically follows
//!                       with TCP close.
//!
//! Stdout/stderr capture is PROVISIONAL — `out` / `err` response
//! fields are empty until `*out*` / `*err*` dynamic-binding lands
//! at D-118 (the analyzer's print primitive currently writes to the
//! process stdout, not to a per-session buffer).
//!
//! State chart (ADR-0048 §nREPL chart, filled at this row):
//!
//!     ┌──────────┐  client connect  ┌───────────────┐  clone op  ┌─────────────┐
//!     │  accept  │ ───────────────▶ │ session_init  │ ─────────▶ │op_dispatch  │
//!     └──────────┘                  └───────────────┘            └─────────────┘
//!          ▲                                                            │
//!          │ session_close                                               │ each op
//!          │                                                             ▼
//!     ┌──────────┐                                                ┌─────────────┐
//!     │ closing  │ ◀──── close op / disconnect ────────────────── │  response   │
//!     └──────────┘                                                │   _send     │
//!                                                                 └─────────────┘

const std = @import("std");
const Writer = std.Io.Writer;
const bencode = @import("../runtime/bencode/bencode.zig");
const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const Value = @import("../runtime/value/value.zig").Value;
const bootstrap = @import("../lang/bootstrap.zig");
const print = @import("../runtime/print.zig");
const env_mod = @import("../runtime/env.zig");
const text_io = @import("../runtime/io/text_io.zig");

/// Run the nREPL server until SIGINT / fatal accept error. Writes a
/// `.nrepl-port` file in CWD on bind so CIDER + similar clients can
/// auto-discover the port (the standard nREPL convention).
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    port: u16,
) !void {
    // Address + bind. IpAddress.parseIp4 + listen are the Zig 0.16
    // canonical sync server pattern (cf. lib/std/Io/net.zig:246).
    var addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try std.Io.net.IpAddress.listen(&addr, io, .{});
    defer server.deinit(io);

    // Write `.nrepl-port` in CWD for CIDER auto-discovery. Zig 0.16's
    // Server doesn't expose the bound address after listen() — when
    // the user requests `port = 0` (auto-assign), we'd need a getsockname
    // surface; today we just record the requested port. PROVISIONAL: --port 0 auto-assign needs getsockname surface [refs: D-117, feature_deps.yaml#runtime/nrepl/auto_port]
    try writeNreplPortFile(io, arena, port);
    defer cleanupNreplPortFile(io);

    try stdout.print("nREPL server started on port {d} on host 127.0.0.1 - nrepl://127.0.0.1:{d}\n", .{ port, port });
    try stdout.flush();

    // Set up the Runtime once; sessions share it for now (single-
    // thread means no race). Multi-session = Phase B (D-117).
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    // println/print/prn route to the server's process stdout (matches the
    // current D-118 "no per-session capture" state) on one writer (D-096).
    rt.stdout = stdout;

    var env = try Env.init(&rt);
    defer env.deinit();

    driver.installVTable(&rt);

    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();
    // Full bootstrap prefix (resolver + primitives + macros + data-readers +
    // *ns* var) — see repl.zig; a bare registerAll leaves *ns* unresolved when
    // test.clj loads (ADR-0083).
    try bootstrap.setupCorePrefix(&rt, &env, &macro_table);

    // ADR-0056 Cycle 2c + Cycle 3 (D-452 Part B): AOT-restore the whole eager
    // bootstrap (core + non-core libs; prefix done above).
    bootstrap.loadCoreAot(arena, &rt, &env, @import("bootstrap_cache").data) catch |err| {
        try stderr.print("nrepl: bootstrap failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return err;
    };

    // Accept loop — sequential per ADR-0048 nREPL chart. Second
    // connection waits in the kernel accept queue until the first
    // closes; CIDER / lein reconnect-after-disconnect work without
    // hanging (vs. the "single accept then exit" anti-pattern).
    var session_counter: u32 = 0;
    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            // Handle transient accept errors gracefully; only
            // permanent errors (e.g. socket closed by signal) break
            // the loop.
            else => {
                try stderr.print("nrepl: accept failed: {s}; exiting\n", .{@errorName(err)});
                try stderr.flush();
                return;
            },
        };
        defer stream.close(io);
        session_counter += 1;
        handleSession(io, arena, stderr, &rt, &env, &macro_table, stream, session_counter) catch |err| {
            try stderr.print("nrepl: session {d} error: {s}\n", .{ session_counter, @errorName(err) });
            try stderr.flush();
            // Continue to accept the next connection.
        };
    }
}

fn handleSession(
    io: std.Io,
    arena: std.mem.Allocator,
    stderr: *Writer,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    stream: std.Io.net.Stream,
    session_id: u32,
) !void {
    _ = stderr;
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &rbuf);
    var stream_writer = stream.writer(io, &wbuf);
    const conn_reader = &stream_reader.interface;
    const conn_writer = &stream_writer.interface;

    // Read whatever the client sends as a stream of bencode dicts.
    // Each iteration consumes one dict + handles its op.
    var session_id_str_buf: [32]u8 = undefined;
    const session_id_str = try std.fmt.bufPrint(&session_id_str_buf, "{d}-{d}", .{ @intFromPtr(rt) & 0xFFFF, session_id });

    while (true) {
        // Peek the buffered bytes; if empty + EOF, exit the loop.
        const more = conn_reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        _ = more;
        if (conn_reader.bufferedLen() == 0) break;

        const bytes = conn_reader.buffered();
        const r = bencode.decode(arena, bytes) catch break;
        conn_reader.toss(r.consumed);

        const request = r.value;
        if (request != .dict) continue;

        const op = (bencode.dictGet(request, "op") orelse continue);
        const id_val = bencode.dictGet(request, "id");
        const op_name = if (op == .str) op.str else continue;

        if (std.mem.eql(u8, op_name, "clone")) {
            try replyClone(arena, conn_writer, session_id_str, id_val);
        } else if (std.mem.eql(u8, op_name, "describe")) {
            try replyDescribe(arena, conn_writer, session_id_str, id_val);
        } else if (std.mem.eql(u8, op_name, "eval")) {
            // `eval`: run the `code` string, emit one `value` per top-level form.
            try replyEval(arena, conn_writer, rt, env, macro_table, request, "code", true, session_id_str, id_val);
        } else if (std.mem.eql(u8, op_name, "load-file")) {
            // `load-file` (CIDER `C-c C-k` / `, e b`): run the whole `file` buffer,
            // emit only the LAST form's value (clj load-file semantics).
            try replyEval(arena, conn_writer, rt, env, macro_table, request, "file", false, session_id_str, id_val);
        } else if (std.mem.eql(u8, op_name, "interrupt")) {
            // Single-threaded eval has no preemption point yet (D-117); ack so the
            // client's interrupt round-trip completes cleanly.
            try replyDoneStatus(arena, conn_writer, session_id_str, id_val, &.{"done"});
        } else if (std.mem.eql(u8, op_name, "ls-sessions")) {
            try replyLsSessions(arena, conn_writer, session_id_str, id_val);
        } else if (std.mem.eql(u8, op_name, "close")) {
            try replyClose(arena, conn_writer, session_id_str, id_val);
            break;
        } else {
            // Unknown op — bencode dict with status ["error" "unknown-op" "done"].
            try replyUnknownOp(arena, conn_writer, op_name, session_id_str, id_val);
        }
    }
}

fn writeBencode(w: *Writer, alloc: std.mem.Allocator, v: bencode.Decoded) !void {
    const bytes = try bencode.encode(alloc, v);
    defer alloc.free(bytes);
    try w.writeAll(bytes);
    try w.flush();
}

fn statusEntry(arena: std.mem.Allocator, items: []const []const u8) !bencode.Decoded {
    const list_items = try arena.alloc(bencode.Decoded, items.len);
    for (items, 0..) |s, i| list_items[i] = .{ .str = s };
    return .{ .list = list_items };
}

fn baseDict(arena: std.mem.Allocator, session_id: []const u8, id_val: ?bencode.Decoded) ![]bencode.Decoded.Entry {
    var n: usize = 1; // session
    if (id_val) |_| n += 1;
    const entries = try arena.alloc(bencode.Decoded.Entry, n);
    entries[0] = .{ .key = "session", .value = .{ .str = session_id } };
    if (id_val) |iv| {
        entries[1] = .{ .key = "id", .value = iv };
    }
    return entries;
}

fn replyClone(arena: std.mem.Allocator, w: *Writer, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    const status = try statusEntry(arena, &.{"done"});
    const new_session = bencode.Decoded.Entry{ .key = "new-session", .value = .{ .str = session_id } };
    const status_e = bencode.Decoded.Entry{ .key = "status", .value = status };
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 2);
    @memcpy(all[0..base.len], base);
    all[base.len] = new_session;
    all[base.len + 1] = status_e;
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyDescribe(arena: std.mem.Allocator, w: *Writer, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    // ops dict with each op pointing at an empty dict (no per-op
    // metadata yet; CIDER tolerates this).
    const op_names = [_][]const u8{ "clone", "describe", "eval", "load-file", "interrupt", "ls-sessions", "close" };
    var op_entries = try arena.alloc(bencode.Decoded.Entry, op_names.len);
    for (op_names, 0..) |name, i| {
        op_entries[i] = .{ .key = name, .value = .{ .dict = &.{} } };
    }
    const ops_dict = bencode.Decoded.Entry{ .key = "ops", .value = .{ .dict = op_entries } };
    const versions_entries = [_]bencode.Decoded.Entry{
        .{ .key = "cljw", .value = .{ .str = "0.1.0-pre" } },
        .{ .key = "nrepl", .value = .{ .str = "0.6.0" } },
    };
    const versions_dict = bencode.Decoded.Entry{ .key = "versions", .value = .{ .dict = &versions_entries } };
    const status_e = bencode.Decoded.Entry{ .key = "status", .value = try statusEntry(arena, &.{"done"}) };
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 3);
    @memcpy(all[0..base.len], base);
    all[base.len] = ops_dict;
    all[base.len + 1] = versions_dict;
    all[base.len + 2] = status_e;
    try writeBencode(w, arena, .{ .dict = all });
}

/// Shared `eval` / `load-file` handler. `code_key` selects which request field
/// holds the source (`"code"` for eval, `"file"` for load-file). `send_each_value`
/// true → emit a `value` per top-level form (REPL eval); false → emit only the
/// LAST form's value (clj `load-file` semantics). Each form's stdout (println /
/// pr / …) is captured and streamed to the client as an `out` message BEFORE its
/// value, so output shows up in the editor REPL, not just the server terminal.
fn replyEval(
    arena: std.mem.Allocator,
    w: *Writer,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    request: bencode.Decoded,
    code_key: []const u8,
    send_each_value: bool,
    session_id: []const u8,
    id_val: ?bencode.Decoded,
) !void {
    const code_v = bencode.dictGet(request, code_key) orelse {
        try replyError(arena, w, try std.fmt.allocPrint(arena, "missing {s}", .{code_key}), session_id, id_val);
        return;
    };
    if (code_v != .str) {
        try replyError(arena, w, "source must be a string", session_id, id_val);
        return;
    }
    const code = code_v.str;

    var reader = Reader.init(arena, code);
    var last_value: ?[]const u8 = null;
    while (true) {
        const form_opt = reader.read() catch |err| {
            try replyError(arena, w, @errorName(err), session_id, id_val);
            break;
        };
        const form = form_opt orelse break;

        const node = analyzeForm(arena, rt, env, null, form, macro_table) catch |err| {
            try replyError(arena, w, @errorName(err), session_id, id_val);
            continue;
        };
        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;

        // Capture this form's stdout (println/print/prn/pr/newline) so it streams
        // to the client as `out`. ADR-0138: bind `*out*` to a fresh string writer
        // for the eval — the capture IS the bound writer VALUE. The binding frame
        // is threadlocal (env.zig current_frame), so each connection thread
        // captures only its own output, exactly as the old threadlocal did.
        const cap_w = try text_io.mintStringWriter(rt);
        var out_frame: env_mod.BindingFrame = .{};
        if (env.findNs("clojure.core")) |core_ns| {
            if (core_ns.resolve("*out*")) |out_var| try out_frame.bindings.put(arena, out_var, cap_w);
        }
        env_mod.pushFrame(&out_frame);
        const result = driver.evalForm(rt, env, &locals, arena, node) catch |err| {
            env_mod.popFrame();
            const captured = text_io.writerBytes(cap_w);
            if (captured.len > 0) try replyOut(arena, w, captured, session_id, id_val);
            try replyError(arena, w, @errorName(err), session_id, id_val);
            continue;
        };
        env_mod.popFrame();
        const captured = text_io.writerBytes(cap_w);
        if (captured.len > 0) try replyOut(arena, w, captured, session_id, id_val);

        var aw: std.Io.Writer.Allocating = .init(arena);
        try print.printResult(rt, env, &aw.writer, result);
        const value_str = try arena.dupe(u8, aw.written());
        if (send_each_value) {
            try replyValue(arena, w, value_str, env, session_id, id_val);
        } else {
            last_value = value_str;
        }
    }
    if (!send_each_value) {
        if (last_value) |lv| try replyValue(arena, w, lv, env, session_id, id_val);
    }

    try replyDoneStatus(arena, w, session_id, id_val, &.{"done"});
}

/// Stream captured stdout to the client (`{out: <text>}`), tied to the eval's
/// session + id so the editor routes it to the right REPL buffer.
fn replyOut(arena: std.mem.Allocator, w: *Writer, text: []const u8, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 1);
    @memcpy(all[0..base.len], base);
    all[base.len] = .{ .key = "out", .value = .{ .str = text } };
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyValue(arena: std.mem.Allocator, w: *Writer, value_str: []const u8, env: *Env, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 2);
    @memcpy(all[0..base.len], base);
    all[base.len] = .{ .key = "value", .value = .{ .str = value_str } };
    const ns_name = if (env.current_ns) |ns| ns.name else "user";
    all[base.len + 1] = .{ .key = "ns", .value = .{ .str = ns_name } };
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyDoneStatus(arena: std.mem.Allocator, w: *Writer, session_id: []const u8, id_val: ?bencode.Decoded, items: []const []const u8) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 1);
    @memcpy(all[0..base.len], base);
    all[base.len] = .{ .key = "status", .value = try statusEntry(arena, items) };
    try writeBencode(w, arena, .{ .dict = all });
}

/// `ls-sessions` — the single live session (single-session server today).
fn replyLsSessions(arena: std.mem.Allocator, w: *Writer, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 2);
    @memcpy(all[0..base.len], base);
    const sessions = try arena.alloc(bencode.Decoded, 1);
    sessions[0] = .{ .str = session_id };
    all[base.len] = .{ .key = "sessions", .value = .{ .list = sessions } };
    all[base.len + 1] = .{ .key = "status", .value = try statusEntry(arena, &.{"done"}) };
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyClose(arena: std.mem.Allocator, w: *Writer, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    const status_e = bencode.Decoded.Entry{ .key = "status", .value = try statusEntry(arena, &.{ "done", "session-closed" }) };
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 1);
    @memcpy(all[0..base.len], base);
    all[base.len] = status_e;
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyError(arena: std.mem.Allocator, w: *Writer, msg: []const u8, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 2);
    @memcpy(all[0..base.len], base);
    all[base.len] = .{ .key = "err", .value = .{ .str = msg } };
    all[base.len + 1] = .{ .key = "status", .value = try statusEntry(arena, &.{ "error", "eval-error", "done" }) };
    try writeBencode(w, arena, .{ .dict = all });
}

fn replyUnknownOp(arena: std.mem.Allocator, w: *Writer, op_name: []const u8, session_id: []const u8, id_val: ?bencode.Decoded) !void {
    const base = try baseDict(arena, session_id, id_val);
    var all = try arena.alloc(bencode.Decoded.Entry, base.len + 2);
    @memcpy(all[0..base.len], base);
    const msg = try std.fmt.allocPrint(arena, "unknown op: {s}", .{op_name});
    all[base.len] = .{ .key = "err", .value = .{ .str = msg } };
    all[base.len + 1] = .{ .key = "status", .value = try statusEntry(arena, &.{ "error", "unknown-op", "done" }) };
    try writeBencode(w, arena, .{ .dict = all });
}

fn writeNreplPortFile(io: std.Io, arena: std.mem.Allocator, port: u16) !void {
    const file = try std.Io.Dir.cwd().createFile(io, ".nrepl-port", .{});
    defer file.close(io);
    var fbuf: [16]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    try fw.interface.print("{d}\n", .{port});
    try fw.interface.flush();
    _ = arena;
}

fn cleanupNreplPortFile(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, ".nrepl-port") catch {};
}
