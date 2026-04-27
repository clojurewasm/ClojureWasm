//! Core predicate primitives for the `rt/` namespace.
//!
//! Phase-2 surface (per ROADMAP §9.4 / 2.9): `nil?`, `true?`,
//! `false?`, `identical?`. These are bit-level checks against the
//! NaN-boxed Value representation — no allocation, no vtable detour.
//!
//! `apply` and `type` need a heap-backed list and keyword-interning
//! through the runtime; they land in Phase 3+ once the analyser
//! handles those forms.

const std = @import("std");
const Value = @import("../../runtime/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

fn requireArity(name: []const u8, args: []const Value, n: usize, loc: SourceLocation) !void {
    if (args.len != n)
        return error_mod.setErrorFmt(.eval, .arity_error, loc, "Wrong number of args ({d}) passed to {s} (expected {d})", .{ args.len, name, n });
}

/// `(nil? x)` — true iff `x` is the singleton nil Value.
pub fn nilQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try requireArity("nil?", args, 1, loc);
    return if (args[0].isNil()) .true_val else .false_val;
}

/// `(true? x)` — strict `true` test (NOT general truthiness — that's
/// `(if x ...)`'s job).
pub fn trueQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try requireArity("true?", args, 1, loc);
    return if (args[0] == Value.true_val) .true_val else .false_val;
}

/// `(false? x)` — strict `false` test (the only false-tagged Value;
/// nil and other falsy values do **not** count).
pub fn falseQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try requireArity("false?", args, 1, loc);
    return if (args[0] == Value.false_val) .true_val else .false_val;
}

/// `(identical? a b)` — bit equality on the underlying NaN-boxed u64.
/// Equivalent to Java `==` reference identity in Clojure JVM.
pub fn identicalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try requireArity("identical?", args, 2, loc);
    return if (args[0] == args[1]) .true_val else .false_val;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "nil?", .f = &nilQ },
    .{ .name = "true?", .f = &trueQ },
    .{ .name = "false?", .f = &falseQ },
    .{ .name = "identical?", .f = &identicalQ },
};

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

test "nil? distinguishes nil from false / 0 / true" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try nilQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{Value.initInteger(0)}, .{}));
    try testing.expectEqual(Value.false_val, try nilQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
}

test "true? is strict true (not Clojure truthiness)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try trueQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
    // Truthy values like 1 / "x" / :foo are NOT true?.
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{Value.initInteger(1)}, .{}));
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try trueQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
}

test "false? is strict false (nil is NOT false?)" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(Value.true_val, try falseQ(&fix.rt, &fix.env, &.{.false_val}, .{}));
    try testing.expectEqual(Value.false_val, try falseQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
    try testing.expectEqual(Value.false_val, try falseQ(&fix.rt, &fix.env, &.{.true_val}, .{}));
}

test "identical? on bit-equal Values is true; differing Values false" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const equal = [_]Value{ Value.initInteger(7), Value.initInteger(7) };
    try testing.expectEqual(Value.true_val, try identicalQ(&fix.rt, &fix.env, &equal, .{}));

    const different = [_]Value{ Value.initInteger(7), Value.initInteger(8) };
    try testing.expectEqual(Value.false_val, try identicalQ(&fix.rt, &fix.env, &different, .{}));
}

test "predicates reject wrong arity" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    try testing.expectError(error.ArityError, nilQ(&fix.rt, &fix.env, &.{}, .{}));
    try testing.expectError(error.ArityError, identicalQ(&fix.rt, &fix.env, &.{.nil_val}, .{}));
}

test "register installs every entry under rt/" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const rt_ns = fix.env.findNs("rt").?;
    try register(&fix.env, rt_ns);
    inline for (ENTRIES) |it| {
        try testing.expect(rt_ns.resolve(it.name) != null);
    }
}
