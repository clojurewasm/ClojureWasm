// SPDX-License-Identifier: EPL-2.0
//! Error / exception primitives for the `rt/` namespace.
//!
//! Surface:
//!
//! - `(ex-info msg data)` → ExInfo Value (cause = nil)
//! - `(ex-info msg data cause)` → ExInfo Value
//! - `(ex-message x)` → string Value if `x` is an ex-info, else nil
//! - `(ex-data x)` → data Value if `x` is an ex-info, else nil
//! - `(ex-cause x)` → the cause exception, else nil
//! - `(__assertion-error msg)` → internal AssertionError carrier for
//!   `(assert …)` (D-192)
//!
//! Mirroring Clojure's `clojure.core` definitions: `ex-message` and
//! `ex-data` accept any Value and return nil for non-exceptions
//! (rather than throwing). This keeps them safe to use on already-
//! caught Values whose precise type is uncertain.
//!
//! `(throw x)` / `(try …)` are wired in the TreeWalk evaluator
//! (`evalThrow` / `evalTry`); the `last_thrown_exception` dispatch
//! slot these primitives read is load-bearing.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const ex_info = @import("../../runtime/collection/ex_info.zig");
const string_collection = @import("../../runtime/collection/string.zig");
const map_mod = @import("../../runtime/collection/map.zig");
const vector_mod = @import("../../runtime/collection/vector.zig");
const keyword_mod = @import("../../runtime/keyword.zig");
const root_set = @import("../../runtime/gc/root_set.zig");

/// `(ex-info msg data)` / `(ex-info msg data cause)`.
///
/// Accepts **any Value** for `data` (not just maps). JVM Clojure
/// requires `data` to be a map or nil; cw v1 currently leaves it
/// loose (the data Value is stored as-is and surfaced by `ex-data`).
pub fn exInfo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("ex-info", args, 2, 3, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "ex-info", .actual = @tagName(args[0].tag()) });
    const msg = string_collection.asString(args[0]);
    const data_v = args[1];
    const cause_v: Value = if (args.len == 3) args[2] else .nil_val;
    return ex_info.alloc(rt, msg, data_v, cause_v);
}

/// `(ex-message x)` — string message if `x` is an ex-info, else nil.
pub fn exMessage(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("ex-message", args, 1, loc);
    const v = args[0];
    if (v.tag() != .ex_info) return .nil_val;
    // Lift the borrowed message slice into a fresh heap String so the
    // returned Value has an independent lifetime (the source ExInfo
    // could be GC'd later in Phase 5+; the message slice would
    // become dangling).
    return string_collection.alloc(rt, ex_info.message(v));
}

/// `(ex-data x)` — data Value if `x` is an ex-info, else nil.
pub fn exData(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ex-data", args, 1, loc);
    const v = args[0];
    if (v.tag() != .ex_info) return .nil_val;
    // ADR-0060: a runtime-synthesized internal error (carries a class
    // name) is NOT an ExceptionInfo — a bare ArithmeticException has no
    // ex-data, matching real Clojure. Only real `(ex-info …)` (class
    // name null) yields data.
    if (ex_info.className(v) != null) return .nil_val;
    return ex_info.data(v);
}

/// `(ex-cause x)` — the cause exception passed as the optional 3rd arg of
/// `(ex-info msg data cause)`, or nil (also nil for a non-ex_info or a
/// causeless ex-info). Matches `Throwable.getCause`.
pub fn exCause(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ex-cause", args, 1, loc);
    const v = args[0];
    if (v.tag() != .ex_info) return .nil_val;
    return ex_info.cause(v);
}

/// `(stack-trace e)` — a cljw-shaped frame seq of a CAUGHT exception (ADR-0140):
/// a vector of `{:ns :fn :file :line :column}` maps, **innermost-first** (clj's
/// `:trace` convention; `info.trace` is innermost-LAST push order so iterate
/// reverse). `:fn` is the BARE fn name, `:ns` separate (the renderer combines them
/// `<ns>/<fn>`). NOT a JVM `StackTraceElement` 4-vector (ADR-0059: no JVM —
/// class/method are fictions; the map keeps `column` a 4-vector drops). A non-ex_info
/// OR a never-thrown ex-info (no captured trace) returns an EMPTY vector, so
/// `clojure.stacktrace` keeps the AD-029 marker for a frame-less exception. Frames
/// are already user-only (elided at push time, AD-024). Reads the ExInfo's own
/// deep-copied frames (ADR-0120), so a re-thrown / stored exception is honest.
pub fn stackTrace(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("stack-trace", args, 1, loc);
    const v = args[0];
    if (v.tag() != .ex_info) return vector_mod.fromSlice(rt, &.{});
    const frames = ex_info.originTrace(v) orelse return vector_mod.fromSlice(rt, &.{});

    // Interned keys are stable GC roots once interned.
    const kw_ns = try keyword_mod.intern(rt, null, "ns");
    const kw_fn = try keyword_mod.intern(rt, null, "fn");
    const kw_file = try keyword_mod.intern(rt, null, "file");
    const kw_line = try keyword_mod.intern(rt, null, "line");
    const kw_column = try keyword_mod.intern(rt, null, "column");

    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(rt.gpa);
    // GC-root the in-progress pairs (stack) + accumulated maps (locals) across
    // each `string.alloc` + `fromLiteralPairs`'s single alloc. A string is placed
    // into the rooted `pairs` immediately after alloc so the next alloc can't
    // collect it; `items` uses rt.gpa (not GC), so append never collects.
    var pairs: [10]Value = undefined;
    var pairs_sp: u16 = 0;
    var gc_frame: root_set.EvalFrame = .{ .stack = &pairs, .sp = &pairs_sp, .locals = &.{}, .parent = root_set.eval_frame_head };
    root_set.eval_frame_head = &gc_frame;
    defer root_set.eval_frame_head = gc_frame.parent;

    var i: usize = frames.len;
    while (i > 0) {
        i -= 1;
        const f = frames[i];
        pairs[0] = kw_ns;
        pairs[1] = .nil_val;
        pairs[2] = kw_fn;
        pairs[3] = .nil_val;
        pairs[4] = kw_file;
        pairs[5] = .nil_val;
        pairs[6] = kw_line;
        pairs[7] = Value.initInteger(@intCast(f.line));
        pairs[8] = kw_column;
        pairs[9] = Value.initInteger(@intCast(f.column));
        pairs_sp = 10;
        gc_frame.locals = items.items;
        if (f.ns) |s| pairs[1] = try string_collection.alloc(rt, s);
        gc_frame.locals = items.items;
        if (f.fn_name) |s| pairs[3] = try string_collection.alloc(rt, s);
        gc_frame.locals = items.items;
        if (f.file) |s| pairs[5] = try string_collection.alloc(rt, s);
        gc_frame.locals = items.items;
        const m = try map_mod.fromLiteralPairs(rt, pairs[0..10]);
        try items.append(rt.gpa, m);
        gc_frame.locals = items.items;
    }
    return vector_mod.fromSlice(rt, items.items);
}

/// `(__assertion-error msg)` — internal carrier that `(assert …)` throws
/// (D-192). Unlike `ex-info`, it has a class name (`AssertionError`) so it is
/// catchable as `AssertionError` / `Error` / `Throwable` but NOT `Exception`,
/// and carries no ex-data — matching JVM `new AssertionError(msg)`.
pub fn assertionError(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("__assertion-error", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "__assertion-error", .actual = @tagName(args[0].tag()) });
    return ex_info.allocException(rt, string_collection.asString(args[0]), "AssertionError");
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "ex-info", .f = &exInfo },
    .{ .name = "ex-message", .f = &exMessage },
    .{ .name = "ex-data", .f = &exData },
    .{ .name = "ex-cause", .f = &exCause },
    .{ .name = "stack-trace", .f = &stackTrace },
    .{ .name = "__assertion-error", .f = &assertionError },
};

/// Intern `ex-info` / `ex-message` / `ex-data` builtins into `rt_ns`.
/// Mirrors the shape used by `lang/primitive/math.register` and
/// `lang/primitive/core.register`; the aggregator
/// `lang/primitive.registerAll` calls this once at startup.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,
    env: Env,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) !void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
        self.env = try Env.init(&self.rt);
    }

    fn deinit(self: *TestFixture) void {
        self.env.deinit();
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "(ex-info \"boom\" 42) builds an ex_info Value" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const msg = try string_collection.alloc(&fix.rt, "boom");
    const args = [_]Value{ msg, Value.initInteger(42) };
    const v = try exInfo(&fix.rt, &fix.env, &args, .{});
    try testing.expect(v.tag() == .ex_info);
    try testing.expectEqualStrings("boom", ex_info.message(v));
    try testing.expectEqual(Value.initInteger(42), ex_info.data(v));
    try testing.expect(ex_info.cause(v).isNil());
}

test "(ex-info ...) with cause as 3rd arg" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const inner_msg = try string_collection.alloc(&fix.rt, "inner");
    const inner_args = [_]Value{ inner_msg, .nil_val };
    const inner = try exInfo(&fix.rt, &fix.env, &inner_args, .{});

    const outer_msg = try string_collection.alloc(&fix.rt, "outer");
    const outer_args = [_]Value{ outer_msg, .nil_val, inner };
    const outer = try exInfo(&fix.rt, &fix.env, &outer_args, .{});
    try testing.expectEqualStrings("inner", ex_info.message(ex_info.cause(outer)));
}

test "ex-info rejects non-string message" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const args = [_]Value{ Value.initInteger(1), .nil_val };
    try testing.expectError(error.TypeError, exInfo(&fix.rt, &fix.env, &args, .{}));
}

test "ex-info arity errors at 0/1/4 args" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const args0 = [_]Value{};
    try testing.expectError(error.ArityError, exInfo(&fix.rt, &fix.env, &args0, .{}));

    const msg = try string_collection.alloc(&fix.rt, "x");
    const args1 = [_]Value{msg};
    try testing.expectError(error.ArityError, exInfo(&fix.rt, &fix.env, &args1, .{}));

    const args4 = [_]Value{ msg, .nil_val, .nil_val, .nil_val };
    try testing.expectError(error.ArityError, exInfo(&fix.rt, &fix.env, &args4, .{}));
}

test "ex-message returns nil for non-ex-info inputs" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const args = [_]Value{Value.initInteger(7)};
    const out = try exMessage(&fix.rt, &fix.env, &args, .{});
    try testing.expect(out.isNil());
}

test "ex-message returns the duped message for an ex-info" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const msg = try string_collection.alloc(&fix.rt, "hi");
    const make_args = [_]Value{ msg, Value.initInteger(0) };
    const ex = try exInfo(&fix.rt, &fix.env, &make_args, .{});

    const args = [_]Value{ex};
    const got = try exMessage(&fix.rt, &fix.env, &args, .{});
    try testing.expect(got.tag() == .string);
    try testing.expectEqualStrings("hi", string_collection.asString(got));
}

test "ex-data returns the data Value (or nil for non-ex-info)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const msg = try string_collection.alloc(&fix.rt, "m");
    const make_args = [_]Value{ msg, Value.initInteger(99) };
    const ex = try exInfo(&fix.rt, &fix.env, &make_args, .{});

    const args = [_]Value{ex};
    const got = try exData(&fix.rt, &fix.env, &args, .{});
    try testing.expectEqual(Value.initInteger(99), got);

    const non_ex = [_]Value{Value.initInteger(0)};
    const got2 = try exData(&fix.rt, &fix.env, &non_ex, .{});
    try testing.expect(got2.isNil());
}
