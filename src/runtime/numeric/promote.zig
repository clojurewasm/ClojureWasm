// SPDX-License-Identifier: EPL-2.0
//! Cross-type numeric dispatch + auto-promotion paths per F-005
//! and ROADMAP §9.7 / 5.10.
//!
//! Scope: Long ↔ BigInt promotion for `+ - *`; the `/`
//! integer/integer → Ratio path lives in `divPromoting`. Ratio
//! arithmetic (`+ - * /` over ratio / mixed ratio⊗integer operands,
//! plus ratio⊗float contagion) routes through `ratioArith`. BigDecimal
//! cross-mixed cases (e.g. `(* 1/2 0.5M)`) route through
//! `bigdecContagion` — both operands are coerced to BigDecimal (the
//! `.ratio` arm of `coerceToBigDecimal` handles ratio⊗BigDecimal) and
//! exact BigDecimal arithmetic runs.
//!
//! Float-contagion follows JVM Clojure: any float operand makes the
//! result float (precision loss accepted). i48 overflow (cw v1's
//! immediate-Long boundary) silently promotes to BigInt — never to
//! float (ROADMAP §9.7 / 5.10: "Long overflow (i48 boundary) silently
//! promotes to BigInt for + / - / *"). Per F-005 cljw's `+` / `-` / `*`
//! auto-promote (JVM throws on overflow there); per ADR-0100 the `'`
//! ops (`+'` / `-'` / `*'`) also promote (matching JVM, where the `'`
//! ops are the auto-promoting family) — so in cljw both spellings share
//! this one promoting path. There is no raise-on-overflow strict family.

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
    if (v.tag() == .big_decimal) {
        // value = unscaled · 10^(−scale). Lossy (float-contagion semantics).
        const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);
        return managedToF64(rt, bd.unscaled.m) * std.math.pow(f64, 10.0, @floatFromInt(-bd.scale));
    }
    return 0.0; // unreachable for caller that ran ensureNumeric
}

fn managedToF64(rt: *Runtime, m: *const Managed) f64 {
    // Correct (round-trips through base-10) but slow: toString +
    // parseFloat. The lossiness is a Clojure feature (float-contagion
    // semantics). A direct limb→f64 conversion is a future perf option.
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
/// (`Value.initInteger`) when it fits in i48, else BigInt. This is the
/// canonical "exact i64 → Value" entry: unlike `Value.initInteger` (which
/// silently demotes an out-of-i48 value to a lossy Float), it keeps a
/// 64-bit value exact by promoting to BigInt. Callers producing a full-width
/// i64 (arithmetic carry-out, `Long/parseLong`, the `Long` bit statics) must
/// route through here rather than `initInteger`.
pub fn wrapI64(rt: *Runtime, x: i64) !Value {
    if (inI48(x)) return Value.initInteger(x);
    var m = try Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.set(x);
    // The "exact i64 → Value" entry is the Long-overflow path — `x` is an
    // i64 so it always fits a Long → heap-Long (D-165: no `N`, class Long).
    return try big_int.allocFromManaged(rt, &m, .long);
}

/// True iff `v` is a GENUINE BigInt (heap integer with `.bigint` origin) —
/// NOT a heap-boxed Long (D-165). The discriminator for arithmetic result
/// origin: a heap-Long operand keeps the result Long-category.
fn isTrueBigInt(v: Value) bool {
    return v.tag() == .big_int and big_int.originOf(v) == .bigint;
}

/// Wrap an integer arithmetic result `r` with the correct origin given the
/// operands (D-165): a genuine-BigInt operand forces a BigInt result
/// (`(+ 1N 2)`→3N); otherwise the operands are Long-category (inline or
/// heap-Long) → `wrapManaged` range-splits (inline / heap-Long / — past i64
/// — BigInt per AD-008). This is the operand-propagation the both-`isInt`
/// dispatch misses (a heap-Long is tag `.big_int`, so it falls to the
/// Managed arm yet must stay a Long).
fn wrapArith(rt: *Runtime, r: *const Managed, a: Value, b: Value) !Value {
    if (isTrueBigInt(a) or isTrueBigInt(b)) return try big_int.allocFromManaged(rt, r, .bigint);
    return try wrapManaged(rt, r);
}

/// Collapse a Managed integer to a Value: immediate-Long when it fits i48,
/// else BigInt. The Managed-input counterpart of `wrapI64` for callers that
/// already hold a Managed (e.g. the ratio numerator/denominator accessors),
/// so a small numerator prints as `3`, not `3N`.
pub fn wrapManaged(rt: *Runtime, m: *const Managed) !Value {
    // Long-category collapse (ratio/div/quot results): fits i48 → inline
    // Long; fits i64 → heap-Long (`.long`, D-165: no `N`); exceeds i64 → a
    // genuine BigInt (`.bigint`) — a Long can't hold > i64, so the value is
    // necessarily arbitrary-precision.
    if (m.toInt(i64) catch null) |x| {
        if (inI48(x)) return Value.initInteger(x);
        return try big_int.allocFromManaged(rt, m, .long);
    }
    return try big_int.allocFromManaged(rt, m, .bigint);
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

    // Denominator collapsed to 1: the quotient is exact. A ratio operation
    // that reduces to a whole number yields a BigInt in clj (`(* 1/2 4)`→2N,
    // `(+ 1/3 2/3)`→1N — JVM Ratio's Numbers.divide returns BigInt when denom=1),
    // NOT a Long. `ratioArith` is only reached with a ratio operand, so the
    // collapse is always a genuine BigInt (F-005 expressed-behaviour parity).
    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var rem = try Managed.init(rt.gc.infra);
    defer rem.deinit();
    try q.divTrunc(&rem, &rn, &rd);
    return try big_int.allocFromManaged(rt, &q, .bigint);
}

const BdOp = enum { add, sub, mul };

/// Promote a non-float numeric operand to BigDecimal: a BigDecimal passes
/// through; int / BigInt become scale-0; a ratio yields its exact decimal (or
/// `error.NonTerminatingDecimal`). Caller guarantees `v` is non-float numeric.
fn coerceToBigDecimal(rt: *Runtime, v: Value) !Value {
    return switch (v.tag()) {
        .big_decimal => v,
        .big_int => try big_decimal_mod.allocFromManagedScale(rt, big_int.asManaged(v), 0),
        .ratio => blk: {
            const r = v.decodePtr(*const ratio_mod.Ratio);
            break :blk try big_decimal_mod.allocFromRatioParts(rt, r.numer.m, r.denom.m);
        },
        else => try big_decimal_mod.allocFromI64Scale(rt, @as(i64, v.asInteger()), 0),
    };
}

/// BigDecimal contagion for +/−/×: at least one operand is a BigDecimal and
/// neither is a float (float wins, handled by the caller's earlier branch).
/// Both operands are promoted to BigDecimal, then exact BigDecimal arithmetic
/// runs. JVM: a BigDecimal makes the whole expression BigDecimal unless a
/// double is present.
fn bigdecContagion(rt: *Runtime, a: Value, b: Value, op: BdOp) !Value {
    const ba = try coerceToBigDecimal(rt, a);
    const bb = try coerceToBigDecimal(rt, b);
    return switch (op) {
        .add => big_decimal_mod.allocAdd(rt, ba, bb),
        .sub => big_decimal_mod.allocSub(rt, ba, bb),
        .mul => big_decimal_mod.allocMul(rt, ba, bb),
    };
}

/// `a + b` with auto-promotion. Both inputs MUST be numeric (caller
/// runs `ensureNumeric` first).
pub fn addPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) + toF64(rt, b));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        return try bigdecContagion(rt, a, b, .add);
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
        return try big_int.allocAddManaged(rt, &am, &bm, .bigint);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.add(&am, &bm);
    return try wrapArith(rt, &r, a, b);
}

/// `a - b` with auto-promotion.
pub fn subPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) - toF64(rt, b));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        return try bigdecContagion(rt, a, b, .sub);
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
        return try big_int.allocSubManaged(rt, &am, &bm, .bigint);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.sub(&am, &bm);
    return try wrapArith(rt, &r, a, b);
}

/// `a * b` with auto-promotion.
pub fn mulPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(toF64(rt, a) * toF64(rt, b));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        return try bigdecContagion(rt, a, b, .mul);
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
        return try big_int.allocMulManaged(rt, &am, &bm, .bigint);
    }
    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try r.mul(&am, &bm);
    return try wrapArith(rt, &r, a, b);
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

    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const ba = try coerceToBigDecimal(rt, a);
        const bb = try coerceToBigDecimal(rt, b);
        return try big_decimal_mod.allocDiv(rt, ba, bb);
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
    // Category contagion (D-165, mirrors quotPromoting): a BigInt operand
    // forces a BigInt result (`(/ 6N 3)`→2N); both-Long collapses via
    // wrapManaged (fits i48 → inline, fits i64 → heap-Long, else BigInt).
    if (isTrueBigInt(a) or isTrueBigInt(b) or a.tag() == .ratio or b.tag() == .ratio) return try big_int.allocFromManaged(rt, &q, .bigint);
    return try wrapManaged(rt, &q);
}

/// Exact sign of a numeric Value: `.lt` (negative) / `.eq` (zero) /
/// `.gt` (positive). Used by `modPromoting`'s floor-mod correction.
/// Exact (no float round-off) for the integer / BigInt / Ratio cases;
/// the float arm reads the f64 sign directly.
fn numSign(v: Value) std.math.Order {
    return switch (v.tag()) {
        .integer => std.math.order(@as(i64, v.asInteger()), 0),
        .char => std.math.order(@as(i64, v.asChar()), 0),
        .float => std.math.order(v.asFloat(), 0),
        .big_int => big_int.asManaged(v).toConst().orderAgainstScalar(0),
        .ratio => v.decodePtr(*const ratio_mod.Ratio).numer.m.toConst().orderAgainstScalar(0),
        .big_decimal => v.decodePtr(*const big_decimal_mod.BigDecimal).unscaled.m.toConst().orderAgainstScalar(0),
        else => .eq,
    };
}

/// `(quot a b)` — truncating division toward zero, across the numeric
/// tower. Mirrors JVM `Numbers.quotient`: any float operand → float
/// trunc; a BigInt/Ratio operand → BigInt result (category contagion);
/// both Long → Long. Divide-by-zero raises for EVERY category including
/// float (unlike `/`, where the float path yields IEEE Inf). A BigDecimal
/// operand → BigDecimal integral quotient (`big_decimal.allocQuotient`,
/// scale `max(0, sa−sb)`); a non-terminating ratio operand → arith error.
pub fn quotPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        const bd = toF64(rt, b);
        if (bd == 0) return error.DivideByZero;
        return Value.initFloat(@trunc(toF64(rt, a) / bd));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const ba = try coerceToBigDecimal(rt, a);
        const bb = try coerceToBigDecimal(rt, b);
        return try big_decimal_mod.allocQuotient(rt, ba, bb);
    }

    // Exact path (Long / BigInt / Ratio). a/b = (an*bd)/(ad*bn); the
    // truncated quotient is divTrunc of that cross-multiplied fraction.
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

    var numer = try Managed.init(rt.gc.infra);
    defer numer.deinit();
    var denom = try Managed.init(rt.gc.infra);
    defer denom.deinit();
    try numer.mul(&ap.num, &bp.den);
    try denom.mul(&ap.den, &bp.num);
    if (denom.eqlZero()) return error.DivideByZero;

    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try q.divTrunc(&r, &numer, &denom);

    // Category contagion: a BigInt/Ratio operand forces a BigInt result
    // (so `(quot 10N 3N)` prints `3N`); both-Long stays Long.
    if (isTrueBigInt(a) or isTrueBigInt(b) or a.tag() == .ratio or b.tag() == .ratio) return try big_int.allocFromManaged(rt, &q, .bigint);
    return try wrapManaged(rt, &q);
}

/// `(rem a b)` — remainder with the sign of the dividend, across the
/// tower. Defined as `a - (quot a b) * b` so it rides the existing
/// promotion ladder (F-011 commonization): a ratio dividend yields a
/// Ratio, a float yields a float, BigInt stays BigInt.
pub fn remPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    const q = try quotPromoting(rt, a, b);
    const qb = try mulPromoting(rt, q, b);
    return try subPromoting(rt, a, qb);
}

/// `(mod a b)` — floor-mod (result has the sign of the divisor), across
/// the tower. `rem` plus the JVM correction: when the remainder is
/// non-zero and its sign differs from the divisor, add the divisor.
pub fn modPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    const r = try remPromoting(rt, a, b);
    const rs = numSign(r);
    if (rs == .eq) return r;
    if (rs != numSign(b)) return try addPromoting(rt, r, b);
    return r;
}

/// Truncate a numeric Value toward zero to an i64. `error.OutOfRange`
/// when the integer part exceeds i64 (callers map this to the JVM
/// "value out of range" coercion error) or the float is NaN/Inf;
/// `error.NotANumber` for a non-numeric tag. Shared by `int` / `long`
/// (F-011 DRY) so both coerce the whole tower identically.
pub fn truncToI64(rt: *Runtime, v: Value) !i64 {
    switch (v.tag()) {
        .integer => return @as(i64, v.asInteger()),
        .char => return @as(i64, v.asChar()),
        .float => {
            const f = v.asFloat();
            if (!std.math.isFinite(f) or f >= 9.223372036854776e18 or f <= -9.223372036854776e18)
                return error.OutOfRange;
            return @intFromFloat(f);
        },
        .big_int => return big_int.asManaged(v).toInt(i64) catch error.OutOfRange,
        .ratio => {
            const ratio = v.decodePtr(*const ratio_mod.Ratio);
            var q = try Managed.init(rt.gc.infra);
            defer q.deinit();
            var r = try Managed.init(rt.gc.infra);
            defer r.deinit();
            try q.divTrunc(&r, ratio.numer.m, ratio.denom.m);
            return q.toInt(i64) catch error.OutOfRange;
        },
        .big_decimal => {
            const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);
            // value = unscaled * 10^(-scale); trunc toward zero is
            // divTrunc(unscaled, 10^scale) for scale>0, an exact multiply
            // for scale<=0.
            var u = try bd.unscaled.m.cloneWithDifferentAllocator(rt.gc.infra);
            defer u.deinit();
            if (bd.scale == 0) return u.toInt(i64) catch error.OutOfRange;
            var pow = try tenPow(rt, if (bd.scale < 0) -bd.scale else bd.scale);
            defer pow.deinit();
            if (bd.scale > 0) {
                var q = try Managed.init(rt.gc.infra);
                defer q.deinit();
                var r = try Managed.init(rt.gc.infra);
                defer r.deinit();
                try q.divTrunc(&r, &u, &pow);
                return q.toInt(i64) catch error.OutOfRange;
            }
            var p = try Managed.init(rt.gc.infra);
            defer p.deinit();
            try p.mul(&u, &pow);
            return p.toInt(i64) catch error.OutOfRange;
        },
        else => return error.NotANumber,
    }
}

/// Read an EXACT integer Value as an i64 — no truncation, no widening.
/// `error.NotAnInteger` for a float / ratio / non-numeric (the JVM
/// `Math/*Exact` family takes `long` params, so those have no matching
/// overload); `error.OutOfRange` when a BigInt exceeds i64. Distinct from
/// `truncToI64` (which truncates floats / ratios toward zero). Shared by
/// the `Math/*Exact` statics.
pub fn exactI64(v: Value) !i64 {
    return switch (v.tag()) {
        .integer => @as(i64, v.asInteger()),
        .big_int => big_int.asManaged(v).toInt(i64) catch error.OutOfRange,
        else => error.NotAnInteger,
    };
}

/// `10^exp` as an owned Managed (exp ≥ 0). Caller must `deinit`.
fn tenPow(rt: *Runtime, exp: i32) !Managed {
    var acc = try Managed.init(rt.gc.infra);
    errdefer acc.deinit();
    try acc.set(1);
    var ten = try Managed.init(rt.gc.infra);
    defer ten.deinit();
    try ten.set(10);
    var scratch = try Managed.init(rt.gc.infra);
    defer scratch.deinit();
    var k: i32 = exp;
    while (k > 0) : (k -= 1) {
        try scratch.mul(&acc, &ten);
        std.mem.swap(Managed, &acc, &scratch);
    }
    return acc;
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

test "ratioArith addPromoting (1/2 + 1/2) collapses to BigInt 1N (clj parity)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    try testing.expect(half.tag() == .ratio);
    const v = try addPromoting(&fix.rt, half, half);
    // clj `(+ 1/2 1/2)` → 1N (a BigInt, not Long) — JVM Ratio collapse.
    try testing.expect(v.tag() == .big_int);
    try testing.expect(big_int.originOf(v) == .bigint);
    try testing.expectEqual(@as(i64, 1), try big_int.asManaged(v).toInt(i64));
}

test "ratioArith mulPromoting (1/2 * 4) collapses to BigInt 2N (mixed operand)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    const v = try mulPromoting(&fix.rt, half, Value.initInteger(4));
    try testing.expect(v.tag() == .big_int);
    try testing.expect(big_int.originOf(v) == .bigint);
    try testing.expectEqual(@as(i64, 2), try big_int.asManaged(v).toInt(i64));
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

test "quotPromoting Long stays Long; truncates toward zero" {
    var fix = Fixture.init();
    defer fix.deinit();

    const q = try quotPromoting(&fix.rt, Value.initInteger(10), Value.initInteger(3));
    try testing.expect(q.tag() == .integer);
    try testing.expectEqual(@as(i48, 3), q.asInteger());

    const qn = try quotPromoting(&fix.rt, Value.initInteger(-7), Value.initInteger(3));
    try testing.expectEqual(@as(i48, -2), qn.asInteger());
}

test "quotPromoting Ratio operand forces a BigInt result (category contagion)" {
    var fix = Fixture.init();
    defer fix.deinit();

    // (quot 17/2 2) → 4N : ratio operand → BigInt-tagged even though 4 fits a Long.
    const half17 = try divPromoting(&fix.rt, Value.initInteger(17), Value.initInteger(2));
    try testing.expect(half17.tag() == .ratio);
    const q = try quotPromoting(&fix.rt, half17, Value.initInteger(2));
    try testing.expect(q.tag() == .big_int);
    try testing.expectEqual(@as(i64, 4), try big_int.asManaged(q).toInt(i64));
}

test "quotPromoting float trunc; divide-by-zero raises for float (unlike /)" {
    var fix = Fixture.init();
    defer fix.deinit();

    const q = try quotPromoting(&fix.rt, Value.initFloat(10.5), Value.initInteger(3));
    try testing.expect(q.isFloat());
    try testing.expectEqual(@as(f64, 3.0), q.asFloat());

    try testing.expectError(error.DivideByZero, quotPromoting(&fix.rt, Value.initFloat(10.0), Value.initInteger(0)));
}

test "remPromoting sign-of-dividend; modPromoting sign-of-divisor" {
    var fix = Fixture.init();
    defer fix.deinit();

    const r = try remPromoting(&fix.rt, Value.initInteger(-7), Value.initInteger(3));
    try testing.expectEqual(@as(i48, -1), r.asInteger());
    const m = try modPromoting(&fix.rt, Value.initInteger(-7), Value.initInteger(3));
    try testing.expectEqual(@as(i48, 2), m.asInteger());

    const r2 = try remPromoting(&fix.rt, Value.initInteger(7), Value.initInteger(-3));
    try testing.expectEqual(@as(i48, 1), r2.asInteger());
    const m2 = try modPromoting(&fix.rt, Value.initInteger(7), Value.initInteger(-3));
    try testing.expectEqual(@as(i48, -2), m2.asInteger());
}

test "truncToI64 over the tower (int / float / bigint / ratio)" {
    var fix = Fixture.init();
    defer fix.deinit();

    try testing.expectEqual(@as(i64, 3), try truncToI64(&fix.rt, Value.initInteger(3)));
    try testing.expectEqual(@as(i64, 3), try truncToI64(&fix.rt, Value.initFloat(3.9)));
    try testing.expectEqual(@as(i64, -3), try truncToI64(&fix.rt, Value.initFloat(-3.9)));

    const seven_halves = try divPromoting(&fix.rt, Value.initInteger(7), Value.initInteger(2));
    try testing.expectEqual(@as(i64, 3), try truncToI64(&fix.rt, seven_halves));

    try testing.expectError(error.NotANumber, truncToI64(&fix.rt, Value.nil_val));
    try testing.expectError(error.OutOfRange, truncToI64(&fix.rt, Value.initFloat(1e30)));
}

test "exactI64 accepts integer / in-range BigInt; rejects float / ratio" {
    var fix = Fixture.init();
    defer fix.deinit();

    try testing.expectEqual(@as(i64, 42), try exactI64(Value.initInteger(42)));

    // A literal beyond i48 is a BigInt in cljw (D-165); exactI64 reads it.
    const big = try mulPromoting(&fix.rt, Value.initInteger((1 << 47) - 1), Value.initInteger(2));
    try testing.expect(big.tag() == .big_int);
    try testing.expectEqual(@as(i64, ((1 << 47) - 1) * 2), try exactI64(big));

    try testing.expectError(error.NotAnInteger, exactI64(Value.initFloat(3.0)));
    const half = try divPromoting(&fix.rt, Value.initInteger(1), Value.initInteger(2));
    try testing.expectError(error.NotAnInteger, exactI64(half));
}
