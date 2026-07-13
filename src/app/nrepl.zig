// SPDX-License-Identifier: EPL-2.0
//! `cljw nrepl` entry point (ADR-0170 re-architecture; supersedes the
//! row-14.10 single-file server). This file only bootstraps the
//! runtime and runs the accept + read loop; the protocol lives in the
//! `nrepl/` package:
//!
//! - `nrepl/transport.zig` — bencode framing (drain-all-buffered
//!   before blocking; >4KiB frames; the session/id echo choke point)
//! - `nrepl/session.zig`   — session registry (distinct clone ids,
//!   per-session `*1`..`*e` + current-ns)
//! - `nrepl/ops.zig`       — the op table (describe derives from it)
//! - `../eval_session.zig` — the shared REPL eval engine (also drives
//!   the CLI REPL)
//!
//! Concurrency model: single-threaded, sequential accept — CIDER
//! multiplexes its sessions over ONE socket, so this serves a full
//! editor session; a second concurrent client waits in the kernel
//! accept queue. True mid-eval interrupt / thread-per-session is
//! D-117 (a) (concurrency gap area).
//!
//! Memory model: per-message scratch arena (decode + reply encode +
//! print buffers — reset after each message) vs the persistent node
//! arena (reader forms / analysis nodes, referenced by defs). The
//! pre-ADR server fed everything into the process arena and grew
//! unboundedly over a long editor session.

const std = @import("std");
const Writer = std.Io.Writer;

const bootstrap = @import("../lang/bootstrap.zig");
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const transport = @import("nrepl/transport.zig");
const session_mod = @import("nrepl/session.zig");
const ops = @import("nrepl/ops.zig");

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

    // Write `.nrepl-port` in CWD for CIDER auto-discovery. The BOUND port,
    // not the requested one: `--port 0` asks the OS to auto-assign, and Zig
    // 0.16's listen() resolves the ephemeral port into `socket.address`.
    const bound_port = server.socket.address.getPort();
    try writeNreplPortFile(io, bound_port);
    defer cleanupNreplPortFile(io);

    try stdout.print("nREPL server started on port {d} on host 127.0.0.1 - nrepl://127.0.0.1:{d}\n", .{ bound_port, bound_port });
    try stdout.flush();

    // Set up the Runtime once; sessions share it (single-threaded, so
    // no data race; per-session isolation is state, not threads).
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    // println/print/prn outside an eval capture route to the server's
    // process stdout on one writer (D-096).
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

    var registry = session_mod.Registry.init(gpa, &rt.gc, io);
    defer registry.deinit();

    // Accept loop — sequential (see module docstring). Reconnect-after-
    // disconnect works: the next connection is accepted after this one
    // closes.
    while (true) {
        const stream = server.accept(io) catch |err| {
            try stderr.print("nrepl: accept failed: {s}; exiting\n", .{@errorName(err)});
            try stderr.flush();
            return;
        };
        defer stream.close(io);
        handleConnection(io, gpa, arena, stderr, &rt, &env, &macro_table, &registry, stream) catch |err| {
            try stderr.print("nrepl: connection error: {s}\n", .{@errorName(err)});
            try stderr.flush();
            // Continue to accept the next connection.
        };
    }
}

fn handleConnection(
    io: std.Io,
    gpa: std.mem.Allocator,
    persist: std.mem.Allocator,
    stderr: *Writer,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    registry: *session_mod.Registry,
    stream: std.Io.net.Stream,
) !void {
    _ = stderr;
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var stream_reader = stream.reader(io, &rbuf);
    var stream_writer = stream.writer(io, &wbuf);
    const conn_reader = &stream_reader.interface;
    const conn_writer = &stream_writer.interface;

    var framer = transport.Framer.init(gpa);
    defer framer.deinit();

    // Per-message scratch (decode + reply encode + print buffers).
    var scratch_arena = std.heap.ArenaAllocator.init(gpa);
    defer scratch_arena.deinit();

    read_loop: while (true) {
        // Drain EVERY complete buffered message before blocking for
        // more bytes — the load-bearing framing fix (ADR-0170): CIDER
        // pipelines requests, and blocking with a complete dict
        // buffered strands them off-by-one.
        while (true) {
            _ = scratch_arena.reset(.retain_capacity);
            const scratch = scratch_arena.allocator();
            const res = framer.next(scratch) catch {
                // Malformed bencode / oversized frame — protocol error;
                // drop the connection (there is no recoverable framing).
                break :read_loop;
            };
            const request = switch (res) {
                .message => |m| m,
                .need_more => break,
            };
            if (request != .dict) continue;
            const op = transport.requestStr(request, "op") orelse continue;
            var ctx = ops.Ctx{
                .rt = rt,
                .env = env,
                .macro_table = macro_table,
                .registry = registry,
                .w = conn_writer,
                .scratch = scratch,
                .persist = persist,
                .request = request,
                .op = op,
            };
            const keep_open = ops.dispatch(&ctx) catch |err| switch (err) {
                error.OutOfMemory => return err,
                // A write failure means the client went away.
                else => break :read_loop,
            };
            if (!keep_open) break :read_loop;
        }

        // Block for more socket bytes.
        _ = conn_reader.fillMore() catch |err| switch (err) {
            error.EndOfStream => break :read_loop,
            else => return err,
        };
        const bytes = conn_reader.buffered();
        if (bytes.len == 0) break :read_loop;
        try framer.feed(bytes);
        conn_reader.toss(bytes.len);
    }
}

fn writeNreplPortFile(io: std.Io, port: u16) !void {
    const file = try std.Io.Dir.cwd().createFile(io, ".nrepl-port", .{});
    defer file.close(io);
    var fbuf: [16]u8 = undefined;
    var fw = file.writer(io, &fbuf);
    try fw.interface.print("{d}\n", .{port});
    try fw.interface.flush();
}

fn cleanupNreplPortFile(io: std.Io) void {
    std.Io.Dir.cwd().deleteFile(io, ".nrepl-port") catch {};
}
