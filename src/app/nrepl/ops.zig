// SPDX-License-Identifier: EPL-2.0
//! nREPL op table + handlers (ADR-0170). One comptime tuple defines
//! the op surface; both the dispatch map AND the `describe` ops list
//! derive from it, so an op can never ship un-advertised (the
//! pre-ADR describe drift class). Aliases (`complete`/`completions`,
//! `lookup`/`info`/`eldoc`) are separate entries onto one handler —
//! describe advertises every alias, as babashka's does.
//!
//! Response shapes mirror babashka.nrepl (CIDER-proven): the eval
//! error protocol is THREE separate dicts (`err` → `ex`/`root-ex` +
//! `eval-error` → `done`) because CIDER's response cond mis-routes
//! bundled fields; `err` carries the same caret-rendered text the
//! CLI prints (via the shared eval engine → `error_render`).

const std = @import("std");
const Writer = std.Io.Writer;
const build_options = @import("build_options");

const bencode = @import("../../runtime/bencode/bencode.zig");
const transport = @import("transport.zig");
const session_mod = @import("session.zig");
const eval_session = @import("../eval_session.zig");
const introspect = @import("../../runtime/introspect.zig");
const macro_dispatch = @import("../../eval/macro_dispatch.zig");
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const env_mod = @import("../../runtime/env.zig");
const print = @import("../../runtime/print.zig");

/// Everything a handler needs for one request.
pub const Ctx = struct {
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
    registry: *session_mod.Registry,
    /// Connection writer (replies flush here through `transport.respond`).
    w: *Writer,
    /// Per-message scratch arena (reset after the reply flushes).
    scratch: std.mem.Allocator,
    /// Persistent node arena (reader forms / analysis nodes — live
    /// beyond the message because defs can reference them).
    persist: std.mem.Allocator,
    request: bencode.Decoded,
    op: []const u8,

    fn respond(self: *Ctx, entries: []const bencode.Decoded.Entry) !void {
        try transport.respond(self.w, self.scratch, self.request, entries);
    }

    fn respondStatus(self: *Ctx, items: []const []const u8) !void {
        try self.respond(&.{
            .{ .key = "status", .value = try transport.statusValue(self.scratch, items) },
        });
    }

    fn str(self: *Ctx, key: []const u8) ?[]const u8 {
        return transport.requestStr(self.request, key);
    }
};

const OpEntry = struct { name: []const u8, handler: *const fn (*Ctx) anyerror!void };

/// THE op surface. describe derives from this — add here, advertised
/// everywhere.
const op_table = [_]OpEntry{
    .{ .name = "clone", .handler = opClone },
    .{ .name = "close", .handler = opClose },
    .{ .name = "describe", .handler = opDescribe },
    .{ .name = "eval", .handler = opEval },
    .{ .name = "load-file", .handler = opLoadFile },
    .{ .name = "interrupt", .handler = opInterrupt },
    .{ .name = "ls-sessions", .handler = opLsSessions },
    .{ .name = "completions", .handler = opCompletions },
    .{ .name = "complete", .handler = opCompletions },
    .{ .name = "lookup", .handler = opLookup },
    .{ .name = "info", .handler = opLookup },
    .{ .name = "eldoc", .handler = opLookup },
};

const op_map = blk: {
    var kvs: [op_table.len]struct { []const u8, *const fn (*Ctx) anyerror!void } = undefined;
    for (op_table, 0..) |entry, i| kvs[i] = .{ entry.name, entry.handler };
    break :blk std.StaticStringMap(*const fn (*Ctx) anyerror!void).initComptime(kvs);
};

/// Dispatch one decoded request. Returns false when the session should
/// close (the `close` op).
pub fn dispatch(ctx: *Ctx) !bool {
    if (op_map.get(ctx.op)) |handler| {
        try handler(ctx);
        return !std.mem.eql(u8, ctx.op, "close");
    }
    try ctx.respondStatus(&.{ "error", "unknown-op", "done" });
    return true;
}

// --- session ops ---

fn opClone(ctx: *Ctx) anyerror!void {
    const sess = try ctx.registry.clone();
    try ctx.respond(&.{
        .{ .key = "new-session", .value = .{ .str = sess.idSlice() } },
        .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) },
    });
}

fn opClose(ctx: *Ctx) anyerror!void {
    if (ctx.str("session")) |id| _ = ctx.registry.close(id);
    try ctx.respondStatus(&.{ "done", "session-closed" });
}

fn opLsSessions(ctx: *Ctx) anyerror!void {
    var ids: std.ArrayList(bencode.Decoded) = .empty;
    var it = ctx.registry.map.keyIterator();
    while (it.next()) |k| try ids.append(ctx.scratch, .{ .str = k.* });
    try ctx.respond(&.{
        .{ .key = "sessions", .value = .{ .list = ids.items } },
        .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) },
    });
}

fn opInterrupt(ctx: *Ctx) anyerror!void {
    // Single-threaded server: an eval always completes before the next
    // message is read, so an interrupt can only ever find the session
    // idle (true mid-eval interrupt = thread-per-session, D-117 (a)).
    try ctx.respondStatus(&.{ "done", "session-idle" });
}

fn opDescribe(ctx: *Ctx) anyerror!void {
    var op_entries = try ctx.scratch.alloc(bencode.Decoded.Entry, op_table.len);
    for (op_table, 0..) |entry, i| {
        op_entries[i] = .{ .key = entry.name, .value = .{ .dict = &.{} } };
    }
    const nrepl_version = [_]bencode.Decoded.Entry{
        .{ .key = "version-string", .value = .{ .str = "1.3.1" } },
    };
    const versions = [_]bencode.Decoded.Entry{
        .{ .key = "cljw", .value = .{ .str = build_options.version } },
        .{ .key = "nrepl", .value = .{ .dict = &nrepl_version } },
    };
    try ctx.respond(&.{
        .{ .key = "ops", .value = .{ .dict = op_entries } },
        .{ .key = "versions", .value = .{ .dict = &versions } },
        .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) },
    });
}

// --- eval / load-file ---

fn opEval(ctx: *Ctx) anyerror!void {
    try evalImpl(ctx, "code", true);
}

fn opLoadFile(ctx: *Ctx) anyerror!void {
    try evalImpl(ctx, "file", false);
}

/// The bencode sink the shared eval engine drives.
const BencodeSink = struct {
    ctx: *Ctx,

    pub fn onValue(self: *const BencodeSink, text: []const u8) !void {
        const ns_name = if (self.ctx.env.current_ns) |ns| ns.name else "user";
        try self.ctx.respond(&.{
            .{ .key = "value", .value = .{ .str = text } },
            .{ .key = "ns", .value = .{ .str = ns_name } },
        });
    }

    pub fn onOut(self: *const BencodeSink, text: []const u8) !void {
        try self.ctx.respond(&.{.{ .key = "out", .value = .{ .str = text } }});
    }

    pub fn onErrOut(self: *const BencodeSink, text: []const u8) !void {
        try self.ctx.respond(&.{.{ .key = "err", .value = .{ .str = text } }});
    }

    /// The 3-message error protocol's first two dicts (`done` follows
    /// from evalImpl so there is exactly ONE per request).
    pub fn onError(self: *const BencodeSink, rendered: []const u8, err_name: []const u8, thrown: ?Value) !void {
        _ = thrown;
        const c = self.ctx;
        const err_text = if (rendered.len > 0 and rendered[rendered.len - 1] == '\n')
            rendered
        else
            try std.fmt.allocPrint(c.scratch, "{s}\n", .{rendered});
        try c.respond(&.{.{ .key = "err", .value = .{ .str = err_text } }});
        const class_str = try std.fmt.allocPrint(c.scratch, "class {s}", .{err_name});
        try c.respond(&.{
            .{ .key = "ex", .value = .{ .str = class_str } },
            .{ .key = "root-ex", .value = .{ .str = class_str } },
            .{ .key = "status", .value = try transport.statusValue(c.scratch, &.{"eval-error"}) },
        });
    }
};

const Value = @import("../../runtime/value/value.zig").Value;

fn evalImpl(ctx: *Ctx, code_key: []const u8, emit_each: bool) anyerror!void {
    const code = ctx.str(code_key) orelse {
        try ctx.respondStatus(&.{ "error", "no-code", "done" });
        return;
    };
    const sess = try ctx.registry.getOrDefault(ctx.str("session"));

    // ns honoring: an explicit request `ns` must exist (spec:
    // namespace-not-found); otherwise the session's ns, falling back
    // to `user`. The global current_ns is saved/restored so one
    // session's `in-ns` never leaks into another's eval.
    const prior_ns = ctx.env.current_ns;
    if (ctx.str("ns")) |ns_name| {
        const target = ctx.env.findNs(ns_name) orelse {
            try ctx.respondStatus(&.{ "error", "namespace-not-found", "done" });
            return;
        };
        ctx.env.setCurrentNs(target);
    } else if (ctx.env.findNs(sess.ns_name) orelse ctx.env.findNs("user")) |target| {
        ctx.env.setCurrentNs(target);
    }

    const label = if (!emit_each)
        (ctx.str("file-name") orelse "<nrepl>")
    else
        "<nrepl>";

    var sink = BencodeSink{ .ctx = ctx };
    _ = eval_session.evalSource(ctx.rt, ctx.env, ctx.macro_table, ctx.persist, ctx.scratch, .{
        .source = code,
        .source_label = label,
        .stars = &sess.stars,
        .capture_output = true,
        .emit_each_value = emit_each,
    }, &sink) catch |err| {
        // Engine-internal failure (OOM etc.) — not user code. Restore
        // ns bookkeeping, then surface to the connection loop.
        if (ctx.env.current_ns) |cur| sess.ns_name = cur.name;
        if (prior_ns) |p| ctx.env.setCurrentNs(p);
        return err;
    };
    // capture an `in-ns` movement into the session, then restore
    // (setCurrentNs is the single current_ns mutator, ADR-0083).
    if (ctx.env.current_ns) |cur| sess.ns_name = cur.name;
    if (prior_ns) |p| ctx.env.setCurrentNs(p);

    try ctx.respondStatus(&.{"done"});
}

// --- completions ---

const CompletionCollector = struct {
    scratch: std.mem.Allocator,
    items: std.ArrayList(bencode.Decoded) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    /// Completion text prefix for qualified queries (`str/`), empty
    /// for bare ones.
    qualifier: []const u8 = "",
    /// Bounded reply: completion UIs never page this deep, and an
    /// empty prefix would otherwise enumerate every var in the image.
    const cap = 1000;

    fn add(self: *CompletionCollector, c: introspect.Candidate) bool {
        if (self.items.items.len >= cap) return false;
        const text = if (self.qualifier.len > 0)
            std.fmt.allocPrint(self.scratch, "{s}/{s}", .{ self.qualifier, c.name }) catch return false
        else
            c.name;
        const gop = self.seen.getOrPut(self.scratch, text) catch return false;
        if (gop.found_existing) return true;
        var entries = self.scratch.alloc(bencode.Decoded.Entry, if (c.ns) |_| 3 else 2) catch return false;
        entries[0] = .{ .key = "candidate", .value = .{ .str = text } };
        entries[1] = .{ .key = "type", .value = .{ .str = c.kind.label() } };
        if (c.ns) |ns| entries[2] = .{ .key = "ns", .value = .{ .str = ns } };
        self.items.append(self.scratch, .{ .dict = entries }) catch return false;
        return true;
    }
};

fn contextNs(ctx: *Ctx, sess: *session_mod.Session) ?*env_mod.Namespace {
    if (ctx.str("ns")) |ns_name| {
        if (ctx.env.findNs(ns_name)) |ns| return ns;
    }
    return ctx.env.findNs(sess.ns_name) orelse ctx.env.findNs("user");
}

fn opCompletions(ctx: *Ctx) anyerror!void {
    const sess = try ctx.registry.getOrDefault(ctx.str("session"));
    const prefix = ctx.str("prefix") orelse ctx.str("symbol") orelse "";
    var collector = CompletionCollector{ .scratch = ctx.scratch };
    if (prefix.len > 0) {
        const ns = contextNs(ctx, sess);
        if (std.mem.findScalar(u8, prefix, '/')) |slash| {
            collector.qualifier = prefix[0..slash];
            if (introspect.resolveQualifier(ctx.env, ns, prefix[0..slash])) |target| {
                introspect.forEachNsVar(target, prefix[slash + 1 ..], &collector, CompletionCollector.add);
            }
        } else {
            introspect.forEachUnqualified(ctx.env, ns, prefix, &collector, CompletionCollector.add);
        }
    }
    try ctx.respond(&.{
        .{ .key = "completions", .value = .{ .list = collector.items.items } },
        .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) },
    });
}

// --- lookup / info / eldoc ---

fn opLookup(ctx: *Ctx) anyerror!void {
    const sess = try ctx.registry.getOrDefault(ctx.str("session"));
    const is_eldoc = std.mem.eql(u8, ctx.op, "eldoc");
    const sym = ctx.str("sym") orelse ctx.str("symbol") orelse {
        try lookupMiss(ctx, is_eldoc);
        return;
    };
    const v = introspect.lookupVar(ctx.env, contextNs(ctx, sess), sym) orelse {
        try lookupMiss(ctx, is_eldoc);
        return;
    };

    const arglists_str: ?[]const u8 = v.arglists orelse blk: {
        const alv = introspect.varArglistsValue(v) orelse break :blk null;
        var aw: Writer.Allocating = .init(ctx.scratch);
        print.printResult(ctx.rt, ctx.env, &aw.writer, alv) catch break :blk null;
        break :blk aw.written();
    };
    const doc = introspect.varDoc(v);

    if (is_eldoc) {
        var entries: std.ArrayList(bencode.Decoded.Entry) = .empty;
        try entries.append(ctx.scratch, .{ .key = "ns", .value = .{ .str = v.ns.name } });
        try entries.append(ctx.scratch, .{ .key = "name", .value = .{ .str = v.name } });
        try entries.append(ctx.scratch, .{ .key = "eldoc", .value = try eldocLists(ctx.scratch, arglists_str orelse "") });
        const type_str = switch (introspect.varKind(v)) {
            .function, .macro => "function",
            else => "variable",
        };
        try entries.append(ctx.scratch, .{ .key = "type", .value = .{ .str = type_str } });
        if (doc) |d| try entries.append(ctx.scratch, .{ .key = "docstring", .value = .{ .str = d } });
        try entries.append(ctx.scratch, .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) });
        try ctx.respond(entries.items);
        return;
    }

    // info: flat body; lookup: the same body nested under "info" (bb shapes).
    var body: std.ArrayList(bencode.Decoded.Entry) = .empty;
    try body.append(ctx.scratch, .{ .key = "ns", .value = .{ .str = v.ns.name } });
    try body.append(ctx.scratch, .{ .key = "name", .value = .{ .str = v.name } });
    try body.append(ctx.scratch, .{ .key = "arglists-str", .value = .{ .str = arglists_str orelse "" } });
    if (doc) |d| try body.append(ctx.scratch, .{ .key = "doc", .value = .{ .str = d } });

    if (std.mem.eql(u8, ctx.op, "lookup")) {
        try ctx.respond(&.{
            .{ .key = "info", .value = .{ .dict = body.items } },
            .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) },
        });
    } else {
        try body.append(ctx.scratch, .{ .key = "status", .value = try transport.statusValue(ctx.scratch, &.{"done"}) });
        try ctx.respond(body.items);
    }
}

fn lookupMiss(ctx: *Ctx, is_eldoc: bool) !void {
    if (is_eldoc) {
        try ctx.respondStatus(&.{ "done", "no-eldoc" });
    } else {
        try ctx.respondStatus(&.{"done"});
    }
}

/// Convert an arglists display string (`"([x] [x y])"`) into the eldoc
/// wire shape: a list of lists of arg strings. Tolerant parser — a
/// shape it does not recognise yields an empty list (CIDER shows no
/// eldoc rather than garbage).
fn eldocLists(scratch: std.mem.Allocator, arglists_str: []const u8) !bencode.Decoded {
    var arities: std.ArrayList(bencode.Decoded) = .empty;
    var i: usize = 0;
    while (i < arglists_str.len) {
        if (arglists_str[i] != '[') {
            i += 1;
            continue;
        }
        // find the matching close bracket (arg vectors don't nest in
        // rendered arglists except destructuring — treat nested [ ] as
        // part of one arg token)
        var depth: usize = 0;
        var j = i;
        while (j < arglists_str.len) : (j += 1) {
            if (arglists_str[j] == '[') depth += 1;
            if (arglists_str[j] == ']') {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        if (j >= arglists_str.len) break;
        const inner = arglists_str[i + 1 .. j];
        var args: std.ArrayList(bencode.Decoded) = .empty;
        var it = std.mem.tokenizeAny(u8, inner, " \t\n");
        while (it.next()) |tok| try args.append(scratch, .{ .str = tok });
        try arities.append(scratch, .{ .list = args.items });
        i = j + 1;
    }
    return .{ .list = arities.items };
}

// --- tests ---

const testing = std.testing;

test "op_map covers the table and describe derives from the same source" {
    for (op_table) |entry| {
        try testing.expect(op_map.get(entry.name) != null);
    }
    try testing.expect(op_map.get("no-such-op") == null);
}

test "eldocLists parses multi-arity display strings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try eldocLists(arena.allocator(), "([f coll] [f c1 c2])");
    try testing.expectEqual(@as(usize, 2), v.list.len);
    try testing.expectEqual(@as(usize, 2), v.list[0].list.len);
    try testing.expectEqualStrings("f", v.list[0].list[0].str);
    try testing.expectEqualStrings("coll", v.list[0].list[1].str);
    try testing.expectEqual(@as(usize, 3), v.list[1].list.len);
    const empty = try eldocLists(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), empty.list.len);
}
