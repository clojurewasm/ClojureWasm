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
const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");

/// `(nil? x)` — true iff `x` is the singleton nil Value.
pub fn nilQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("nil?", args, 1, loc);
    return if (args[0].isNil()) .true_val else .false_val;
}

/// `(true? x)` — strict `true` test (NOT general truthiness — that's
/// `(if x ...)`'s job).
pub fn trueQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("true?", args, 1, loc);
    return if (args[0] == Value.true_val) .true_val else .false_val;
}

/// `(false? x)` — strict `false` test (the only false-tagged Value;
/// nil and other falsy values do **not** count).
pub fn falseQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("false?", args, 1, loc);
    return if (args[0] == Value.false_val) .true_val else .false_val;
}

/// `(identical? a b)` — bit equality on the underlying NaN-boxed u64.
/// Equivalent to Java `==` reference identity in Clojure JVM.
pub fn identicalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("identical?", args, 2, loc);
    return if (args[0] == args[1]) .true_val else .false_val;
}

/// `(string? x)` — true iff `x` is a String (clojure.core/string?).
pub fn stringQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("string?", args, 1, loc);
    return if (args[0].tag() == .string) .true_val else .false_val;
}

/// `(integer? x)` — true iff `x` is an integer (Long or BigInt;
/// matches clojure.core/integer? which excludes Ratio and
/// BigDecimal).
pub fn integerQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("integer?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .integer or t == .big_int) .true_val else .false_val;
}

/// `(number? x)` — true iff `x` is any numeric (Long / Float / BigInt
/// / Ratio / BigDecimal). Matches clojure.core/number?.
pub fn numberQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("number?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .integer or t == .float or t == .big_int or t == .ratio or t == .big_decimal) .true_val else .false_val;
}

/// `(symbol? x)` — true iff `x` is a Symbol Value.
pub fn symbolQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("symbol?", args, 1, loc);
    return if (args[0].tag() == .symbol) .true_val else .false_val;
}

/// `(keyword? x)` — true iff `x` is a Keyword Value.
pub fn keywordQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("keyword?", args, 1, loc);
    return if (args[0].tag() == .keyword) .true_val else .false_val;
}

/// `(vector? x)` — true iff `x` is a persistent Vector.
pub fn vectorQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("vector?", args, 1, loc);
    return if (args[0].tag() == .vector) .true_val else .false_val;
}

/// `(list? x)` — true iff `x` is a persistent List
/// (NOT lazy-seq / cons / chunked-cons — those are `seq?` only).
pub fn listQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("list?", args, 1, loc);
    return if (args[0].tag() == .list) .true_val else .false_val;
}

/// `(map? x)` — true iff `x` is an array-map / hash-map / sorted-map.
pub fn mapQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("map?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .array_map or t == .hash_map or t == .sorted_map) .true_val else .false_val;
}

/// `(set? x)` — true iff `x` is a hash-set or sorted-set.
pub fn setQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("set?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .hash_set or t == .sorted_set) .true_val else .false_val;
}

/// `(fn? x)` — true iff `x` is callable as a function:
/// builtin_fn (NaN-box-immediate function pointer like `+`),
/// fn_val (user `(fn [...] ...)` closure), or multi_fn.
/// JVM Clojure's clojure.core/fn? tests `IFn` minus `Var` —
/// cw v1 mirrors the same intent at the Value.Tag layer.
pub fn fnQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("fn?", args, 1, loc);
    const t = args[0].tag();
    return if (t == .builtin_fn or t == .fn_val or t == .multi_fn) .true_val else .false_val;
}

/// `(boolean? x)` — true iff `x` is one of the booleans `true` / `false`.
/// nil is NOT a boolean.
pub fn booleanQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("boolean?", args, 1, loc);
    return if (args[0] == Value.true_val or args[0] == Value.false_val) .true_val else .false_val;
}

/// `(char? x)` — true iff `x` is a Character (single Unicode codepoint).
pub fn charQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("char?", args, 1, loc);
    return if (args[0].tag() == .char) .true_val else .false_val;
}

/// `(float? x)` — true iff `x` is a double-precision float (IEEE-754
/// 64-bit). Matches clojure.core/float? (which on JVM returns true
/// for both Float and Double; cw v1 has only one float tag).
pub fn floatQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("float?", args, 1, loc);
    return if (args[0].tag() == .float) .true_val else .false_val;
}

/// `(ratio? x)` — true iff `x` is a Ratio (numer/denom pair of BigInts).
pub fn ratioQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("ratio?", args, 1, loc);
    return if (args[0].tag() == .ratio) .true_val else .false_val;
}

/// `(decimal? x)` — true iff `x` is a BigDecimal. Matches
/// clojure.core/decimal?.
pub fn decimalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("decimal?", args, 1, loc);
    return if (args[0].tag() == .big_decimal) .true_val else .false_val;
}

/// `(some? x)` — true iff `x` is not nil. The non-nil counterpart of
/// `nil?`. Matches clojure.core/some?.
pub fn someQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("some?", args, 1, loc);
    return if (args[0].isNil()) .false_val else .true_val;
}

/// `(not x)` — Clojure truthiness inversion. Returns true when x is
/// nil or false; otherwise returns false. NOT a strict-true test
/// (see `false?` for that).
pub fn notFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("not", args, 1, loc);
    return if (args[0].isNil() or args[0] == Value.false_val) .true_val else .false_val;
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
    .{ .name = "string?", .f = &stringQ },
    .{ .name = "integer?", .f = &integerQ },
    .{ .name = "number?", .f = &numberQ },
    .{ .name = "symbol?", .f = &symbolQ },
    .{ .name = "keyword?", .f = &keywordQ },
    .{ .name = "vector?", .f = &vectorQ },
    .{ .name = "list?", .f = &listQ },
    .{ .name = "map?", .f = &mapQ },
    .{ .name = "set?", .f = &setQ },
    .{ .name = "fn?", .f = &fnQ },
    .{ .name = "boolean?", .f = &booleanQ },
    .{ .name = "char?", .f = &charQ },
    .{ .name = "float?", .f = &floatQ },
    .{ .name = "ratio?", .f = &ratioQ },
    .{ .name = "decimal?", .f = &decimalQ },
    .{ .name = "some?", .f = &someQ },
    .{ .name = "not", .f = &notFn },
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
