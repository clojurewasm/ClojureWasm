//! Arithmetic + comparison primitives for the `rt/` namespace.
//!
//! Phase-2 surface (per ROADMAP §9.4 / 2.8): `+`, `-`, `*`, `=`,
//! `<`, `>`, `<=`, `>=`, plus `compare` for completeness.
//!
//! Numeric tower: Phase-2 deals with i48 (the NaN-boxing range) and
//! f64. Mixed-type calls widen to f64 — Clojure's contagion rule.
//! Integer overflow promotes to float automatically because
//! `Value.initInteger` falls back to `initFloat` outside the i48
//! window (see `runtime/value.zig`).
//!
//! Division (Ratio) and mod / rem ship in Phase 5+ alongside heap
//! support for Ratios.

const std = @import("std");
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const promote = @import("../../runtime/numeric/promote.zig");

// --- numeric helpers ---

fn anyFloat(args: []const Value) bool {
    for (args) |v| {
        if (v.tag() == .float) return true;
    }
    return false;
}

fn toF64(v: Value) f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @floatFromInt(v.asInteger()),
        else => 0.0, // caller has already type-checked
    };
}

fn toI64(v: Value) i64 {
    return switch (v.tag()) {
        .integer => v.asInteger(),
        else => 0,
    };
}

fn ensureNumeric(args: []const Value, name: []const u8, loc: SourceLocation) !void {
    for (args) |v| {
        switch (v.tag()) {
            .integer, .float, .big_int, .ratio, .big_decimal => continue,
            else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(t) }),
        }
    }
}

// --- arithmetic ---

/// `(+ ...)` — 0 args → 0, 1 arg → identity, N args → fold via
/// `promote.addPromoting`. i48 overflow auto-promotes to BigInt
/// (per ROADMAP §9.7 / 5.10 + F-005); float is contagious.
pub fn plus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "+", loc);
    if (args.len == 0) return Value.initInteger(0);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = try promote.addPromoting(rt, acc, args[i]);
    }
    return acc;
}

/// `(- x ...)` — 1 arg negates; N args subtract from the first via
/// `promote.subPromoting`. 0 args is an error (matches Clojure).
pub fn minus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "-", loc);
    if (args.len == 0)
        return error_catalog.raise(.arity_below_min, loc, .{ .got = @as(usize, 0), .fn_name = "-", .min = @as(usize, 1) });
    if (args.len == 1) {
        return try promote.subPromoting(rt, Value.initInteger(0), args[0]);
    }
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = try promote.subPromoting(rt, acc, args[i]);
    }
    return acc;
}

/// `(* ...)` — 0 args → 1, 1 arg → identity, N args → fold via
/// `promote.mulPromoting`.
pub fn star(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try ensureNumeric(args, "*", loc);
    if (args.len == 0) return Value.initInteger(1);
    var acc = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        acc = try promote.mulPromoting(rt, acc, args[i]);
    }
    return acc;
}

// --- comparison ---

/// Run `pred` pairwise across `args`, short-circuiting on `false`.
/// Used by `<` / `>` / `<=` / `>=`.
fn pairwise(name: []const u8, args: []const Value, loc: SourceLocation, comptime pred: fn (a: f64, b: f64) bool) !Value {
    try ensureNumeric(args, name, loc);
    if (args.len < 2) return Value.true_val; // (< 1) and (<) are true in Clojure
    if (anyFloat(args)) {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (!pred(toF64(args[i - 1]), toF64(args[i]))) return Value.false_val;
        }
    } else {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = toI64(args[i - 1]);
            const b = toI64(args[i]);
            // Compare via f64 so the predicate is defined once. i48
            // values fit losslessly in f64.
            if (!pred(@floatFromInt(a), @floatFromInt(b))) return Value.false_val;
        }
    }
    return Value.true_val;
}

fn pLT(a: f64, b: f64) bool {
    return a < b;
}
fn pGT(a: f64, b: f64) bool {
    return a > b;
}
fn pLE(a: f64, b: f64) bool {
    return a <= b;
}
fn pGE(a: f64, b: f64) bool {
    return a >= b;
}
fn pEQ(a: f64, b: f64) bool {
    return a == b;
}

/// `(= ...)` — Phase-2: numeric equality only. The general `=`
/// (compare-by-value across types) lands once heap collections do.
pub fn equals(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return pairwise("=", args, loc, pEQ);
}

pub fn lt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return pairwise("<", args, loc, pLT);
}
pub fn gt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return pairwise(">", args, loc, pGT);
}
pub fn le(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return pairwise("<=", args, loc, pLE);
}
pub fn ge(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    return pairwise(">=", args, loc, pGE);
}

/// `(compare x y)` — returns -1 / 0 / 1. Phase-2 covers numerics only.
pub fn compare(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    if (args.len != 2)
        return error_catalog.raise(.arity_not_expected, loc, .{ .fn_name = "compare", .got = args.len, .expected = @as(usize, 2) });
    try ensureNumeric(args, "compare", loc);
    if (anyFloat(args)) {
        const a = toF64(args[0]);
        const b = toF64(args[1]);
        const c: i64 = if (a < b) -1 else if (a > b) 1 else 0;
        return Value.initInteger(c);
    }
    const a = toI64(args[0]);
    const b = toI64(args[1]);
    const c: i64 = if (a < b) -1 else if (a > b) 1 else 0;
    return Value.initInteger(c);
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "+", .f = &plus },
    .{ .name = "-", .f = &minus },
    .{ .name = "*", .f = &star },
    .{ .name = "=", .f = &equals },
    .{ .name = "<", .f = &lt },
    .{ .name = ">", .f = &gt },
    .{ .name = "<=", .f = &le },
    .{ .name = ">=", .f = &ge },
    .{ .name = "compare", .f = &compare },
};

/// Register the math primitives into `rt_ns`.
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

test "plus identity / nullary / multi-arg integer / float contagion" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 0), (try plus(&fix.rt, &fix.env, &.{}, .{})).asInteger());
    try testing.expectEqual(@as(i48, 6), (try plus(&fix.rt, &fix.env, &.{
        Value.initInteger(1),
        Value.initInteger(2),
        Value.initInteger(3),
    }, .{})).asInteger());
    try testing.expectApproxEqAbs(@as(f64, 3.5), (try plus(&fix.rt, &fix.env, &.{
        Value.initFloat(1.5),
        Value.initInteger(2),
    }, .{})).asFloat(), 1e-9);
}

test "minus: negation with one arg, subtraction with N" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, -5), (try minus(&fix.rt, &fix.env, &.{
        Value.initInteger(5),
    }, .{})).asInteger());
    try testing.expectEqual(@as(i48, 4), (try minus(&fix.rt, &fix.env, &.{
        Value.initInteger(10),
        Value.initInteger(3),
        Value.initInteger(3),
    }, .{})).asInteger());
    try testing.expectError(error.ArityError, minus(&fix.rt, &fix.env, &.{}, .{}));
}

test "star: nullary 1, multi-arg product" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    try testing.expectEqual(@as(i48, 1), (try star(&fix.rt, &fix.env, &.{}, .{})).asInteger());
    try testing.expectEqual(@as(i48, 24), (try star(&fix.rt, &fix.env, &.{
        Value.initInteger(2),
        Value.initInteger(3),
        Value.initInteger(4),
    }, .{})).asInteger());
}

test "equals / lt / gt / le / ge — numeric pairwise" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();

    const ones = [_]Value{ Value.initInteger(1), Value.initInteger(1) };
    try testing.expectEqual(Value.true_val, try equals(&fix.rt, &fix.env, &ones, .{}));

    const ascending = [_]Value{
        Value.initInteger(1),
        Value.initInteger(2),
        Value.initInteger(3),
    };
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &ascending, .{}));
    try testing.expectEqual(Value.true_val, try le(&fix.rt, &fix.env, &ascending, .{}));
    try testing.expectEqual(Value.false_val, try gt(&fix.rt, &fix.env, &ascending, .{}));

    const equal_run = [_]Value{
        Value.initInteger(2),
        Value.initInteger(2),
        Value.initInteger(2),
    };
    try testing.expectEqual(Value.true_val, try le(&fix.rt, &fix.env, &equal_run, .{}));
    try testing.expectEqual(Value.true_val, try ge(&fix.rt, &fix.env, &equal_run, .{}));
    try testing.expectEqual(Value.false_val, try lt(&fix.rt, &fix.env, &equal_run, .{}));

    // Trivial arities: (<) / (< 1) are true in Clojure.
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &.{}, .{}));
    try testing.expectEqual(Value.true_val, try lt(&fix.rt, &fix.env, &.{Value.initInteger(1)}, .{}));
}

test "compare returns -1 / 0 / 1" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const cases = [_]struct {
        a: i48,
        b: i48,
        want: i48,
    }{
        .{ .a = 1, .b = 2, .want = -1 },
        .{ .a = 2, .b = 2, .want = 0 },
        .{ .a = 3, .b = 2, .want = 1 },
    };
    for (cases) |c| {
        const args = [_]Value{ Value.initInteger(c.a), Value.initInteger(c.b) };
        try testing.expectEqual(c.want, (try compare(&fix.rt, &fix.env, &args, .{})).asInteger());
    }
}

test "non-numeric arg yields TypeError" {
    var fix: TestFixture = undefined;
    try fix.init(testing.allocator);
    defer fix.deinit();
    const args = [_]Value{ Value.initInteger(1), .nil_val };
    try testing.expectError(error.TypeError, plus(&fix.rt, &fix.env, &args, .{}));
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
