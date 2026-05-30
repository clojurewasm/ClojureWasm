// SPDX-License-Identifier: EPL-2.0
//! Cross-type numeric dispatch + auto-promotion paths per F-005
//! and ROADMAP §9.7 / 5.10.
//!
//! Scope: Long ↔ BigInt promotion for `+ - *`; the `/`
//! integer/integer → Ratio path lives in `divPromoting`. Ratio
//! arithmetic (`+ - * /` over ratio / mixed ratio⊗integer operands,
//! plus ratio⊗float contagion) routes through `ratioArith`. BigDecimal
//! cross-mixed cases (e.g. `(* 1/2 0.5M)`) still raise — they land when
//! such expressions become Clojure-reachable.
//!
//! Float-contagion follows JVM Clojure: any float operand makes the
//! result float (precision loss accepted). i48 overflow (cw v1's
//! immediate-Long boundary) silently promotes to BigInt — never to
//! float — matching the JVM behaviour for `+'` / `-'` / `*'` rather
//! than the unchecked `+` / `-` / `*` (Phase 5.10 ROADMAP text:
//! "Long overflow (i48 boundary) silently promotes to BigInt for
//! + / - / *"). The "raise on overflow" `+'` family lands at 5.10.c.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const big_int = @import("big_int.zig");
const nb = @import("../value/nan_box.zig");

const Managed = std.math.big.int.Managed;

fn inI48(x: i64) bool {
    return x >= nb.NB_I48_MIN and x <= nb.NB_I48_MAX;
}

fn toF64(rt: *Runtime, v: Value) f64 {
    if (v.isFloat()) return v.asFloat();
    if (v.isInt()) return @floatFromInt(@as(i64, v.asInteger()));
    if (v.tag() == .big_int) {
        // Lossy: BigInt → f64. Acceptable for float-contagious paths
        // where the user already opted into float semantics.
        return managedToF64(rt, big_int.asManaged(v));
    }
    if (v.tag() == .ratio) {
        const r = v.decodePtr(*const ratio_mod.Ratio);
        return managedToF64(rt, r.numer.m) / managedToF64(rt, r.denom.m);
    }
    return 0.0; // unreachable for caller that ran ensureNumeric
}

fn managedToF64(rt: *Runtime, m: *const Managed) f64 {
    // Best-effort conversion. For Phase 5.10.a, fall back to
    // toString + parseFloat. The lossy nature is a Clojure feature
    // (float-contagion semantics); Phase 17 may specialise.
    const s = m.toString(rt.gc.infra, 10, .lower) catch return 0.0;
    defer rt.gc.infra.free(s);
    return std.fmt.parseFloat(f64, s) catch 0.0;
}

/// Allocate a Managed on `rt.gc.infra` initialised from `v`. Caller
/// owns and must `deinit` the returned Managed.
fn coerceToManaged(rt: *Runtime, v: Value) !Managed {
    if (v.isInt()) {
        var m = try Managed.init(rt.gc.infra);
        errdefer m.deinit();
        try m.set(@as(i64, v.asInteger()));
        return m;
    }
    if (v.tag() == .big_int) {
        return try big_int.asManaged(v).cloneWithDifferentAllocator(rt.gc.infra);
    }
    return error.NotAnInteger;
}

/// Wrap an i64 result as a Value, choosing immediate-Long
/// (`Value.initInteger`) when it fits in i48, else BigInt.
fn wrapI64(rt: *Runtime, x: i64) !Value {
    if (inI48(x)) return Value.initInteger(x);
    var m = try Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.set(x);
    return try big_int.allocFromManaged(rt, &m);
}

/// Collapse a Managed integer to a Value: immediate-Long when it fits i48,
/// else BigInt. Public counterpart of `wrapI64` for callers that already
/// hold a Managed (e.g. the ratio numerator/denominator accessors), so a
/// small numerator prints as `3`, not `3N`.
pub fn wrapManaged(rt: *Runtime, m: *const Managed) !Value {
    // `toInt` errors when the value exceeds i64; `catch null` folds that into
    // "doesn't fit a Long" so the BigInt path below handles it.
    if (m.toInt(i64) catch null) |x| {
        if (inI48(x)) return Value.initInteger(x);
    }
    return try big_int.allocFromManaged(rt, m);
}

const big_decimal_mod = @import("big_decimal.zig");
const ratio_mod = @import("ratio.zig");

/// Numerator / denominator of a numeric operand as owned Manageds. A
/// ratio yields its stored pair; an integer / BigInt yields `value/1`.
/// Caller owns both and must `deinit` them.
const RatioParts = struct { num: Managed, den: Managed };

fn partsOf(rt: *Runtime, v: Value) !RatioParts {
    if (v.tag() == .ratio) {
        const r = v.decodePtr(*const ratio_mod.Ratio);
        var num = try r.numer.m.cloneWithDifferentAllocator(rt.gc.infra);
        errdefer num.deinit();
        const den = try r.denom.m.cloneWithDifferentAllocator(rt.gc.infra);
        return .{ .num = num, .den = den };
    }
    var num = try coerceToManaged(rt, v);
    errdefer num.deinit();
    var den = try Managed.init(rt.gc.infra);
    try den.set(1);
    return .{ .num = num, .den = den };
}

const RatioOp = enum { add, sub, mul, div };

/// Rational arithmetic over operands where at least one is a ratio (the
/// other may be ratio / integer / BigInt). Computes the result as a
/// numerator/denominator Managed pair, then reduces via
/// `allocFromManagedPair`; when the denominator collapses to 1 the exact
/// integer quotient is returned (Long if it fits i48, else BigInt) —
/// matching JVM Clojure, where `(+ 1/2 1/2)` is `1`, not `1/1`.
fn ratioArith(rt: *Runtime, a: Value, b: Value, op: RatioOp) !Value {
    var ap = try partsOf(rt, a);
    defer {
        ap.num.deinit();
        ap.den.deinit();
    }
    var bp = try partsOf(rt, b);
    defer {
        bp.num.deinit();
        bp.den.deinit();
    }

    var rn = try Managed.init(rt.gc.infra);
    defer rn.deinit();
    var rd = try Managed.init(rt.gc.infra);
    defer rd.deinit();

    switch (op) {
        .mul => {
            try rn.mul(&ap.num, &bp.num);
            try rd.mul(&ap.den, &bp.den);
        },
        .div => {
            // (an/ad) / (bn/bd) = (an*bd) / (ad*bn)
            try rn.mul(&ap.num, &bp.den);
            try rd.mul(&ap.den, &bp.num);
        },
        .add, .sub => {
            // (an*bd ± bn*ad) / (ad*bd)
            var lhs = try Managed.init(rt.gc.infra);
            defer lhs.deinit();
            var rhs = try Managed.init(rt.gc.infra);
            defer rhs.deinit();
            try lhs.mul(&ap.num, &bp.den);
            try rhs.mul(&bp.num, &ap.den);
            if (op == .add) try rn.add(&lhs, &rhs) else try rn.sub(&lhs, &rhs);
            try rd.mul(&ap.den, &bp.den);
        },
    }

    if (rd.eqlZero()) return error.DivideByZero;

    if (try ratio_mod.allocFromManagedPair(rt, &rn, &rd)) |r| return r;

    // Denominator collapsed to 1: the quotient is exact.
    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var rem = try Managed.init(rt.gc.infra);
    defer rem.deinit();
    try q.divTrunc(&rem, &rn, &rd);
    return try wrapManaged(rt, &q);
}

/// `a + b` with auto-promotion. Both inputs MUST be numeric (caller
/// runs `ensureNumeric` first).
pub fn addPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) + toF64(rt, b));
    }
    if (a.tag() == .big_decimal and b.tag() == .big_decimal) {
        return try big_decimal_mod.allocAdd(rt, a, b);
    }
    if (a.tag() == .ratio or b.tag() == .ratio) {
        return try ratioArith(rt, a, b, .add);
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const sum, const overflowed = @addWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, sum);
        // i64 overflow: must go to BigInt.
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocAddManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocAddManaged(rt, &am, &bm);
}

/// `a - b` with auto-promotion.
pub fn subPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) - toF64(rt, b));
    }
    if (a.tag() == .big_decimal and b.tag() == .big_decimal) {
        return try big_decimal_mod.allocSub(rt, a, b);
    }
    if (a.tag() == .ratio or b.tag() == .ratio) {
        return try ratioArith(rt, a, b, .sub);
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const diff, const overflowed = @subWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, diff);
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocSubManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocSubManaged(rt, &am, &bm);
}

/// `a * b` with auto-promotion.
pub fn mulPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) * toF64(rt, b));
    }
    if (a.tag() == .big_decimal and b.tag() == .big_decimal) {
        return try big_decimal_mod.allocMul(rt, a, b);
    }
    if (a.tag() == .ratio or b.tag() == .ratio) {
        return try ratioArith(rt, a, b, .mul);
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const prod, const overflowed = @mulWithOverflow(ai, bi);
        if (overflowed == 0) return try wrapI64(rt, prod);
        var am = try coerceToManaged(rt, a);
        defer am.deinit();
        var bm = try coerceToManaged(rt, b);
        defer bm.deinit();
        return try big_int.allocMulManaged(rt, &am, &bm);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocMulManaged(rt, &am, &bm);
}

/// Strict-integer `a + b`. Returns `error.IntegerOverflow` instead
/// of promoting to BigInt. Mirrors JVM Clojure `+'`. Float operands
/// are still float-contagious (matches JVM).
pub fn addStrict(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) + toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const sum, const overflowed = @addWithOverflow(ai, bi);
        if (overflowed != 0 or !inI48(sum)) return error.IntegerOverflow;
        return Value.initInteger(sum);
    }
    // BigInt arms stay non-overflow (already arbitrary precision).
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocAddManaged(rt, &am, &bm);
}

pub fn subStrict(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) - toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const diff, const overflowed = @subWithOverflow(ai, bi);
        if (overflowed != 0 or !inI48(diff)) return error.IntegerOverflow;
        return Value.initInteger(diff);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocSubManaged(rt, &am, &bm);
}

pub fn mulStrict(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) * toF64(rt, b));
    }
    if (a.isInt() and b.isInt()) {
        const ai: i64 = @as(i64, a.asInteger());
        const bi: i64 = @as(i64, b.asInteger());
        const prod, const overflowed = @mulWithOverflow(ai, bi);
        if (overflowed != 0 or !inI48(prod)) return error.IntegerOverflow;
        return Value.initInteger(prod);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return try big_int.allocMulManaged(rt, &am, &bm);
}

/// `a / b` with auto-promotion. Integer/Integer evenly-divisible
/// returns the quotient; not-evenly-divisible returns a Ratio.
/// Mirrors `Numbers.divide(Number, Number)` in JVM Clojure.
pub fn divPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        // IEEE-754 float division: x/0.0 → ±Inf, 0.0/0.0 → NaN (Zig float
        // division does not trap). JVM Clojure throws DivideByZero only on
        // the integer/integer path below — float division never throws.
        return Value.initFloat(toF64(rt, a) / toF64(rt, b));
    }

    if (a.tag() == .ratio or b.tag() == .ratio) {
        return try ratioArith(rt, a, b, .div);
    }

    // Integer / integer path: build Managed for both, compute gcd,
    // collapse to BigInt if exact; otherwise Ratio.
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();

    if (bm.eqlZero()) return error.DivideByZero;

    const ratio = @import("ratio.zig");
    if (try ratio.allocFromManagedPair(rt, &am, &bm)) |r| {
        return r;
    }
    // Integer-collapse: the result is exact (denominator collapsed
    // to 1). Compute am / bm as a BigInt and wrap, choosing
    // immediate-Long if it fits in i48.
    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try q.divTrunc(&r, &am, &bm);
    if (q.toInt(i64)) |qi| {
        if (inI48(qi)) return Value.initInteger(qi);
    } else |_| {
        // q exceeds i64 range — fall through to BigInt wrap below.
    }
    return try big_int.allocFromManaged(rt, &q);
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() Fixture {
        var fix: Fixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *Fixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "addPromoting (small + small) stays Long" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try addPromoting(&fix.rt, Value.initInteger(7), Value.initInteger(5));
    try testing.expect(v.tag() == .integer);
    try testing.expectEqual(@as(i48, 12), v.asInteger());
}

test "mulPromoting (Long * Long) overflowing i48 promotes to BigInt" {
    var fix = Fixture.init();
    defer fix.deinit();

    // i48 max = 2^47 - 1 = 140737488355327. Multiply by 2 -> 2^48,
    // exceeds i48 range.
    const a = Value.initInteger((1 << 47) - 1);
    const v = try mulPromoting(&fix.rt, a, Value.initInteger(2));
    try testing.expect(v.tag() == .big_int);
}

test "addPromoting (i64 overflow) reaches BigInt arithmetic correctly" {
    var fix = Fixture.init();
    defer fix.deinit();

    // i48 max + i48 max = ~2^48, overflows i48 but fits in i64,
    // still promotes to BigInt because wrapI64 sees inI48 fail.
    const a = Value.initInteger((1 << 47) - 1);
    const v = try addPromoting(&fix.rt, a, a);
    try testing.expect(v.tag() == .big_int);
    // Result = 2 * (2^47 - 1) = 2^48 - 2 = 281474976710654
    try testing.expectEqual(@as(i64, 281474976710654), try big_int.asManaged(v).toInt(i64));
}

test "subPromoting (BigInt - Long) returns BigInt" {
    var fix = Fixture.init();
    defer fix.deinit();

    // Build a BigInt that fits in i64 but not i48 by promoting.
    const big_v = try mulPromoting(&fix.rt, Value.initInteger((1 << 47) - 1), Value.initInteger(2));
    try testing.expect(big_v.tag() == .big_int);

    const v = try subPromoting(&fix.rt, big_v, Value.initInteger(1));
    try testing.expect(v.tag() == .big_int);
    // (2^48 - 2) - 1 = 2^48 - 3
    try testing.expectEqual(@as(i64, (1 << 48) - 3), try big_int.asManaged(v).toInt(i64));
}

test "ratioArith addPromoting (1/2 + 1/2) collapses to Long 1 (no leak)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    try testing.expect(half.tag() == .ratio);
    const v = try addPromoting(&fix.rt, half, half);
    try testing.expect(v.tag() == .integer);
    try testing.expectEqual(@as(i48, 1), v.asInteger());
}

test "ratioArith mulPromoting (1/2 * 4) collapses to Long 2 (mixed operand)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    const v = try mulPromoting(&fix.rt, half, Value.initInteger(4));
    try testing.expect(v.tag() == .integer);
    try testing.expectEqual(@as(i48, 2), v.asInteger());
}

test "ratioArith addPromoting (1/2 + 1/3) stays a ratio (no leak)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    const third = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(3));
    const v = try addPromoting(&fix.rt, half, third);
    try testing.expect(v.tag() == .ratio);
}

test "ratioArith divPromoting (1/2 / 3) is a ratio; (1/2 / 0) raises DivideByZero" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    const v = try divPromoting(&fix.rt, half, Value.initInteger(3));
    try testing.expect(v.tag() == .ratio);
    try testing.expectError(error.DivideByZero, divPromoting(&fix.rt, half, Value.initInteger(0)));
}

test "ratioArith mulPromoting (1/2 * 0.5) is float-contagious -> 0.25" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    const v = try mulPromoting(&fix.rt, half, Value.initFloat(0.5));
    try testing.expect(v.isFloat());
    try testing.expectEqual(@as(f64, 0.25), v.asFloat());
}

test "addPromoting (Long + Float) is float-contagious" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try addPromoting(&fix.rt, Value.initInteger(3), Value.initFloat(0.25));
    try testing.expect(v.isFloat());
    try testing.expectEqual(@as(f64, 3.25), v.asFloat());
}

test "divPromoting (6 / 3) returns immediate Long 2 (exact)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try divPromoting(&fix.rt, Value.initInteger(6), Value.initInteger(3));
    try testing.expect(v.tag() == .integer);
    try testing.expectEqual(@as(i48, 2), v.asInteger());
}

test "divPromoting (1 / 3) returns Ratio 1/3 (not exact)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(3));
    try testing.expect(v.tag() == .ratio);
}

test "divPromoting (5 / 0) raises DivideByZero" {
    var fix = Fixture.init();
    defer fix.deinit();

    try testing.expectError(error.DivideByZero, divPromoting(&fix.rt, Value.initInteger(5), Value.initInteger(0)));
}

test "divPromoting float division by zero yields IEEE Inf / NaN (no trap)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const inf = try divPromoting(&fix.rt, Value.initFloat(1.0), Value.initFloat(0.0));
    try testing.expect(std.math.isPositiveInf(inf.asFloat()));

    const ninf = try divPromoting(&fix.rt, Value.initFloat(-1.0), Value.initFloat(0.0));
    try testing.expect(std.math.isNegativeInf(ninf.asFloat()));

    const nan = try divPromoting(&fix.rt, Value.initFloat(0.0), Value.initFloat(0.0));
    try testing.expect(std.math.isNan(nan.asFloat()));

    // mixed integer/float still goes IEEE (either operand float → float path)
    const mixed = try divPromoting(&fix.rt, Value.initInteger(1), Value.initFloat(0.0));
    try testing.expect(std.math.isPositiveInf(mixed.asFloat()));
}

test "divPromoting (1.0 / 2) returns float 0.5" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try divPromoting(&fix.rt, Value.initFloat(1.0), Value.initInteger(2));
    try testing.expect(v.isFloat());
    try testing.expectEqual(@as(f64, 0.5), v.asFloat());
}

test "mulStrict overflowing i48 raises IntegerOverflow" {
    var fix = Fixture.init();
    defer fix.deinit();

    const a = Value.initInteger((1 << 47) - 1);
    try testing.expectError(error.IntegerOverflow, mulStrict(&fix.rt, a, Value.initInteger(2)));
}

test "addStrict in-range stays Long" {
    var fix = Fixture.init();
    defer fix.deinit();

    const v = try addStrict(&fix.rt, Value.initInteger(3), Value.initInteger(4));
    try testing.expectEqual(@as(i48, 7), v.asInteger());
}
