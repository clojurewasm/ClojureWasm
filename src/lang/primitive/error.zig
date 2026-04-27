//! Error / exception primitives for the `rt/` namespace.
//!
//! Phase 3.10 surface:
//!
//! - `(ex-info msg data)` → ExInfo Value (cause = nil)
//! - `(ex-info msg data cause)` → ExInfo Value
//! - `(ex-message x)` → string Value if `x` is an ex-info, else nil
//! - `(ex-data x)` → data Value if `x` is an ex-info, else nil
//!
//! Mirroring Clojure's `clojure.core` definitions: `ex-message` and
//! `ex-data` accept any Value and return nil for non-exceptions
//! (rather than throwing). This keeps them safe to use on already-
//! caught Values whose precise type is uncertain.
//!
//! The actual `(throw x)` integration lands in Phase 3.11 when the
//! TreeWalk evaluator gets `evalThrow` / `evalTry` and the
//! `last_thrown_exception` threadlocal becomes load-bearing.

const std = @import("std");
const Value = @import("../../runtime/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const ex_info = @import("../../runtime/collection/ex_info.zig");
const string_collection = @import("../../runtime/collection/string.zig");

fn requireArityBetween(
    name: []const u8,
    args: []const Value,
    min: usize,
    max: usize,
    loc: SourceLocation,
) !void {
    if (args.len < min or args.len > max) {
        if (min == max) {
            return error_mod.setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s} (expected {d})", .{ args.len, name, min });
        }
        return error_mod.setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s} (expected {d}-{d})", .{ args.len, name, min, max });
    }
}

/// `(ex-info msg data)` / `(ex-info msg data cause)`.
///
/// Phase 3.10 accepts **any Value** for `data` (not just maps) — once
/// the heap map type ships and `(map? x)` lands, the Tier-A test
/// suite will check `data` is a map and we can tighten the contract.
pub fn exInfo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try requireArityBetween("ex-info", args, 2, 3, loc);
    if (args[0].tag() != .string)
        return error_mod.setErrorFmt(.eval, .type_error, loc, "ex-info: message must be a string, got {s}", .{@tagName(args[0].tag())});
    const msg = string_collection.asString(args[0]);
    const data_v = args[1];
    const cause_v: Value = if (args.len == 3) args[2] else .nil_val;
    return ex_info.alloc(rt, msg, data_v, cause_v);
}

/// `(ex-message x)` — string message if `x` is an ex-info, else nil.
pub fn exMessage(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try requireArityBetween("ex-message", args, 1, 1, loc);
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
    try requireArityBetween("ex-data", args, 1, 1, loc);
    const v = args[0];
    if (v.tag() != .ex_info) return .nil_val;
    return ex_info.data(v);
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
};

/// Intern `ex-info` / `ex-message` / `ex-data` builtins into `rt_ns`.
/// Mirrors the shape used by `lang/primitive/math.register` and
/// `lang/primitive/core.register`; the aggregator
/// `lang/primitive.registerAll` calls this once at startup.
pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f));
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
