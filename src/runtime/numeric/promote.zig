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
const env_mod = @import("../env.zig");
const Runtime = @import("../runtime.zig").Runtime;
const big_int = @import("big_int.zig");
const nb = @import("../value/nan_box.zig");
const host_instance = @import("../host_instance.zig");

const Managed = std.math.big.int.Managed;

pub fn inI48(x: i64) bool {
    return x >= nb.NB_I48_MIN and x <= nb.NB_I48_MAX;
}

/// A numeric Value as clj's `Number.doubleValue`: the one conversion that
/// float contagion, the float arm of `< > <= >= ==`, `double` and the
/// `.doubleValue` method share (F-011). A BigInt is its nearest double, a
/// Ratio is `ratio.toF64` (DECIMAL64 first, as clj's `Ratio.doubleValue`), a
/// BigDecimal is `big_decimal.toFloat` (the double nearest the exact
/// decimal), a char is its code point. A non-number answers 0.0: every
/// caller has type-checked.
pub fn toF64(v: Value) std.mem.Allocator.Error!f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @floatFromInt(@as(i64, v.asInteger())),
        .char => @floatFromInt(v.asChar()),
        .big_int => big_int.asManaged(v).toFloat(f64, .nearest_even)[0],
        .ratio => ratio_mod.toF64(v),
        .big_decimal => big_decimal_mod.toFloat(v),
        else => 0.0,
    };
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

/// Owned scratch for the integer/BigInt arithmetic operand path. `active`
/// is false when the operand is a BigInt (the ref aliases its stored
/// Managed — nothing to free).
const OwnedManaged = struct {
    m: Managed = undefined,
    active: bool = false,
    fn deinit(self: *OwnedManaged) void {
        if (self.active) self.m.deinit();
    }
};

/// Resolve an integer/BigInt operand to a `*const Managed`. A BigInt aliases
/// its stored Managed (PERF: no clone — `add`/`sub`/`mul` only read it;
/// O-039); an immediate Long materialises into `owned` (a stable caller
/// local). Mirrors `partsOf`/`OwnedParts` for the single-Managed path.
fn operandManaged(rt: *Runtime, v: Value, owned: *OwnedManaged) !*const Managed {
    if (v.tag() == .big_int) return big_int.asManaged(v);
    owned.m = try coerceToManaged(rt, v);
    owned.active = true;
    return &owned.m;
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
/// Wrap an integer arithmetic result that was computed DIRECTLY into the
/// `gc.infra`-owned heap Managed `m_ptr` (the add/sub/mul Managed arms) — no
/// temp + clone. Consumes `m_ptr`: on the inline-Long collapse it frees it; on
/// a heap wrap it MOVES it into the BigInt cell (`big_int.wrapManaged`, no
/// limb copy); on error the CALLER's errdefers free it. PERF: O-047 — the
/// bigint_factorial hot path (`(reduce *' …)` grows the accumulator, so every
/// `*` previously cloned ~9 limbs via `allocFromManaged`). [refs: O-047, D-450]
fn wrapArithCell(rt: *Runtime, m_ptr: *Managed, a: Value, b: Value) !Value {
    if (!(isTrueBigInt(a) or isTrueBigInt(b))) {
        // Long-category result: collapse to an immediate Long when it fits i48,
        // else keep as a heap Long (D-165: no `N`) — both via the moved cell.
        if (m_ptr.toInt(i64) catch null) |x| {
            if (inI48(x)) {
                m_ptr.deinit();
                rt.gc.infra.destroy(m_ptr);
                return Value.initInteger(x);
            }
            return try big_int.wrapManaged(rt, m_ptr, .long);
        }
    }
    return try big_int.wrapManaged(rt, m_ptr, .bigint);
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

/// Numerator / denominator of a numeric operand as `*const Managed`. A
/// ratio yields pointers straight into its stored pair (PERF: no clone —
/// the arithmetic only reads the parts; O-037). A non-ratio integer /
/// BigInt is materialised as `value/1` into caller-provided `OwnedParts`
/// storage, which the caller must `deinit`.
const RatioParts = struct { num: *const Managed, den: *const Managed };

/// Owned scratch for the non-ratio operand path. `active` is false for a
/// ratio operand (nothing to free — the parts alias the ratio's BigInts).
const OwnedParts = struct {
    num: Managed = undefined,
    den: Managed = undefined,
    active: bool = false,
    fn deinit(self: *OwnedParts) void {
        if (self.active) {
            self.num.deinit();
            self.den.deinit();
        }
    }
};

/// Resolve `v` into numerator/denominator refs. A ratio aliases its stored
/// pair (zero alloc); a non-ratio materialises `value/1` into `owned` (a
/// stable caller local, so `&owned.num` stays valid for the call scope).
fn partsOf(rt: *Runtime, v: Value, owned: *OwnedParts) !RatioParts {
    if (v.tag() == .ratio) {
        switch (ratio_mod.parts(v)) {
            // big ratio: alias the stored BigInts (zero alloc, O-037).
            .big => |b| return .{ .num = b.n.m, .den = b.d.m },
            // small ratio: materialise the inline i64s into owned scratch (the
            // Managed cross-multiply path; the i64 FAST path in ratioArith
            // avoids reaching here for the common small⊗small case). [ADR-0149]
            .small => |s| {
                owned.num = try Managed.initSet(rt.gc.infra, s.n);
                errdefer owned.num.deinit();
                owned.den = try Managed.initSet(rt.gc.infra, s.d);
                owned.active = true;
                return .{ .num = &owned.num, .den = &owned.den };
            },
        }
    }
    owned.num = try coerceToManaged(rt, v);
    errdefer owned.num.deinit();
    owned.den = try Managed.initSet(rt.gc.infra, 1);
    owned.active = true;
    return .{ .num = &owned.num, .den = &owned.den };
}

const RatioOp = enum { add, sub, mul, div };

/// A numeric operand as an i64 numerator/denominator, IF it is i64-representable
/// for the small-ratio fast path: a small ratio yields its inline pair; an
/// immediate integer yields `int/1`. A big ratio / heap-Long / BigInt / float /
/// BigDecimal yields null → the caller falls back to the Managed path. [ADR-0149]
const SmallParts = struct { n: i64, d: i64 };
fn smallParts(v: Value) ?SmallParts {
    if (v.tag() == .ratio) {
        return switch (ratio_mod.parts(v)) {
            .small => |s| .{ .n = s.n, .d = s.d },
            .big => null,
        };
    }
    if (v.tag() == .integer) return .{ .n = @as(i64, v.asInteger()), .d = 1 };
    return null;
}

/// i64 small-ratio arithmetic fast path. Returns null on ANY i64 overflow (the
/// caller falls back to the Managed path) — `@mulWithOverflow`/`@addWithOverflow`
/// guard every product/sum, since a cross-multiply can overflow even when the
/// operands fit. The reduced result routes through `allocFromI64Pair` (which
/// re-reduces + emits a canonical small ratio, or null on integer-collapse → a
/// BigInt, matching clj's `(+ 1/2 1/2)`→1N). [ADR-0149]
fn ratioArithSmall(rt: *Runtime, ap: SmallParts, bp: SmallParts, op: RatioOp) !?Value {
    var rn: i64 = undefined;
    var rd: i64 = undefined;
    switch (op) {
        .mul => {
            const n, const o1 = @mulWithOverflow(ap.n, bp.n);
            const d, const o2 = @mulWithOverflow(ap.d, bp.d);
            if (o1 != 0 or o2 != 0) return null;
            rn = n;
            rd = d;
        },
        .div => {
            const n, const o1 = @mulWithOverflow(ap.n, bp.d);
            const d, const o2 = @mulWithOverflow(ap.d, bp.n);
            if (o1 != 0 or o2 != 0) return null;
            rn = n;
            rd = d;
        },
        .add, .sub => {
            const ad, const o1 = @mulWithOverflow(ap.n, bp.d);
            const bc, const o2 = @mulWithOverflow(bp.n, ap.d);
            if (o1 != 0 or o2 != 0) return null;
            const s, const o3 = if (op == .add) @addWithOverflow(ad, bc) else @subWithOverflow(ad, bc);
            const d, const o4 = @mulWithOverflow(ap.d, bp.d);
            if (o3 != 0 or o4 != 0) return null;
            rn = s;
            rd = d;
        },
    }
    if (rd == 0) return error.DivideByZero;
    if (try ratio_mod.allocFromI64Pair(rt, rn, rd)) |r| return r;
    // Integer collapse: the reduced denom is 1 → rd | rn exactly. A ratio op
    // that reduces to a whole number yields a BigInt in clj (`(+ 1/2 1/2)`→1N).
    return try big_int.allocFromI64(rt, @divTrunc(rn, rd), .bigint);
}

/// Rational arithmetic over operands where at least one is a ratio (the
/// other may be ratio / integer / BigInt). Computes the result as a
/// numerator/denominator Managed pair, then reduces via
/// `allocFromManagedPair`; when the denominator collapses to 1 the exact
/// integer quotient is returned (Long if it fits i48, else BigInt) —
/// matching JVM Clojure, where `(+ 1/2 1/2)` is `1`, not `1/1`.
fn ratioArith(rt: *Runtime, a: Value, b: Value, op: RatioOp) !Value {
    // PERF: i64 small-ratio fast path (ADR-0149) — when both operands are small
    // ratios / immediate ints, cross-multiply in i64 (overflow → Managed path),
    // skipping all Managed alloc + the gcd/divTrunc scratch. The harmonic-sum
    // hot path (`(+ small-ratio small-ratio)`) lands here.
    if (smallParts(a)) |ap_s| {
        if (smallParts(b)) |bp_s| {
            if (try ratioArithSmall(rt, ap_s, bp_s, op)) |result| return result;
            // overflow → fall through to the Managed path below.
        }
    }

    var owned_a: OwnedParts = .{};
    defer owned_a.deinit();
    const ap = try partsOf(rt, a, &owned_a);
    var owned_b: OwnedParts = .{};
    defer owned_b.deinit();
    const bp = try partsOf(rt, b, &owned_b);

    // PERF: rn/rd/lhs/rhs are transient cross-multiply scratch — one stack
    // arena replaces 2-4 individual GPA malloc/free per ratio op (O-038).
    // `allocFromManagedPair` keeps its own arena, so reducing rn/rd there
    // does not alias this arena.
    var arena = std.heap.ArenaAllocator.init(rt.gc.infra);
    defer arena.deinit();
    const sa = arena.allocator();

    var rn = try Managed.init(sa);
    var rd = try Managed.init(sa);

    switch (op) {
        .mul => {
            try rn.mul(ap.num, bp.num);
            try rd.mul(ap.den, bp.den);
        },
        .div => {
            // (an/ad) / (bn/bd) = (an*bd) / (ad*bn)
            try rn.mul(ap.num, bp.den);
            try rd.mul(ap.den, bp.num);
        },
        .add, .sub => {
            // PERF (O-050): Knuth TAOCP 4.5.1 gcd-first rational add. Inputs are
            // reduced (cljw stores lowest terms), so dividing by g = gcd(ad, bd)
            // FIRST keeps the gcd small (g divides the smaller denominator — for
            // the harmonic-sum hot path the added term's denom is ≤ 50) and SKIPS
            // the final ~80-bit gcd entirely when the denominators are coprime.
            // The result is coprime → `allocFromReducedManagedPair` below (no
            // redundant final gcd). A zero numerator is collapsed there to int 0.
            var g = try Managed.init(sa);
            try g.gcd(ap.den, bp.den);
            var lhs = try Managed.init(sa);
            var rhs = try Managed.init(sa);
            if (g.toConst().orderAgainstScalar(1) == .eq) {
                // coprime denominators: (an*bd ± bn*ad) / (ad*bd) is already reduced.
                try lhs.mul(ap.num, bp.den);
                try rhs.mul(bp.num, ap.den);
                if (op == .add) try rn.add(&lhs, &rhs) else try rn.sub(&lhs, &rhs);
                try rd.mul(ap.den, bp.den);
            } else {
                // q'=ad/g, b'=bd/g; t = an*b' ± bn*q'; g2 = gcd(t, g);
                // rn = t/g2; rd = (q'*bd)/g2  (= lcm/g2, exact since g2 | g | lcm).
                var qp = try Managed.init(sa);
                var bpr = try Managed.init(sa);
                var rem = try Managed.init(sa);
                try qp.divTrunc(&rem, ap.den, &g);
                try bpr.divTrunc(&rem, bp.den, &g);
                try lhs.mul(ap.num, &bpr);
                try rhs.mul(bp.num, &qp);
                var t = try Managed.init(sa);
                if (op == .add) try t.add(&lhs, &rhs) else try t.sub(&lhs, &rhs);
                var g2 = try Managed.init(sa);
                try g2.gcd(&t, &g);
                try rn.divTrunc(&rem, &t, &g2);
                var lcm = try Managed.init(sa);
                try lcm.mul(&qp, bp.den);
                try rd.divTrunc(&rem, &lcm, &g2);
            }
        },
    }

    if (rd.eqlZero()) return error.DivideByZero;

    // add/sub produce an already-reduced (coprime) pair via the Knuth path above,
    // so they skip the redundant final gcd; mul/div still need the full reduce.
    const reduced = if (op == .add or op == .sub)
        try ratio_mod.allocFromReducedManagedPair(rt, &rn, &rd)
    else
        try ratio_mod.allocFromManagedPair(rt, &rn, &rd);
    if (reduced) |r| return r;

    // Denominator collapsed to 1: the quotient is exact. A ratio operation
    // that reduces to a whole number yields a BigInt in clj (`(* 1/2 4)`→2N,
    // `(+ 1/3 2/3)`→1N — JVM Ratio's Numbers.divide returns BigInt when denom=1),
    // NOT a Long. `ratioArith` is only reached with a ratio operand, so the
    // collapse is always a genuine BigInt (F-005 expressed-behaviour parity).
    var q = try Managed.init(sa);
    var rem = try Managed.init(sa);
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
        .ratio => switch (ratio_mod.parts(v)) {
            .big => |b| try big_decimal_mod.allocFromRatioParts(rt, b.n.m, b.d.m),
            .small => |s| blk: {
                var nm = try Managed.initSet(rt.gc.infra, s.n);
                defer nm.deinit();
                var dm = try Managed.initSet(rt.gc.infra, s.d);
                defer dm.deinit();
                break :blk try big_decimal_mod.allocFromRatioParts(rt, &nm, &dm);
            },
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
    const result = try switch (op) {
        .add => big_decimal_mod.allocAdd(rt, ba, bb),
        .sub => big_decimal_mod.allocSub(rt, ba, bb),
        .mul => big_decimal_mod.allocMul(rt, ba, bb),
    };
    if (mathContext(rt)) |mc| {
        return big_decimal_mod.allocRoundPrecision(rt, result, mc.precision, mc.mode);
    }
    return result;
}

/// `a + b` with auto-promotion. Both inputs MUST be numeric (caller
/// runs `ensureNumeric` first).
pub fn addPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(try toF64(a) + try toF64(b));
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
    var oa: OwnedManaged = .{};
    defer oa.deinit();
    const am = try operandManaged(rt, a, &oa);
    var ob: OwnedManaged = .{};
    defer ob.deinit();
    const bm = try operandManaged(rt, b, &ob);
    // PERF: O-047 — compute into the final GC cell; wrapArithCell collapses or
    // MOVES it (no clone). [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.add(am, bm);
    return try wrapArithCell(rt, m_ptr, a, b);
}

/// `a - b` with auto-promotion.
pub fn subPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(try toF64(a) - try toF64(b));
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
    var oa: OwnedManaged = .{};
    defer oa.deinit();
    const am = try operandManaged(rt, a, &oa);
    var ob: OwnedManaged = .{};
    defer ob.deinit();
    const bm = try operandManaged(rt, b, &ob);
    // PERF: O-047 — compute into the final GC cell; no temp + clone. [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.sub(am, bm);
    return try wrapArithCell(rt, m_ptr, a, b);
}

/// `a * b` with auto-promotion.
pub fn mulPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        return Value.initFloat(try toF64(a) * try toF64(b));
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
    var oa: OwnedManaged = .{};
    defer oa.deinit();
    const am = try operandManaged(rt, a, &oa);
    var ob: OwnedManaged = .{};
    defer ob.deinit();
    const bm = try operandManaged(rt, b, &ob);
    // PERF: O-047 — compute into the final GC cell; the bigint_factorial hot
    // path (accumulator grows, every `*` previously cloned its limbs). [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.mul(am, bm);
    return try wrapArithCell(rt, m_ptr, a, b);
}

/// `a / b` with auto-promotion. Integer/Integer evenly-divisible
/// returns the quotient; not-evenly-divisible returns a Ratio.
/// Mirrors `Numbers.divide(Number, Number)` in JVM Clojure.
/// Decode the active MathContext (precision + rounding mode). An integer
/// binding is accepted for callers of the older internal precision var.
const DecimalContext = struct { precision: u32, mode: i64 };
fn mathContext(rt: *Runtime) ?DecimalContext {
    const vp = rt.math_context_var orelse return null;
    const v: *const env_mod.Var = @ptrCast(@alignCast(vp));
    const val = v.deref();
    if (val.tag() == .integer) {
        const p = val.asInteger();
        if (p >= 0 and p <= std.math.maxInt(u32)) return .{ .precision = @intCast(p), .mode = 4 };
    }
    if (val.tag() == .host_instance) {
        const hi = host_instance.asHostInstance(val);
        if (hi.descriptor.fqcn) |fqcn| {
            if (std.mem.eql(u8, fqcn, "java.math.MathContext"))
                return .{ .precision = @intCast(hi.state[0]), .mode = @intCast(hi.state[1]) };
        }
    }
    return null;
}

pub fn divPromoting(rt: *Runtime, a: Value, b: Value) !Value {
    if (a.isFloat() or b.isFloat()) {
        // IEEE-754 float division: x/0.0 → ±Inf, 0.0/0.0 → NaN (Zig float
        // division does not trap). JVM Clojure throws DivideByZero only on
        // the integer/integer path below — float division never throws.
        return Value.initFloat(try toF64(a) / try toF64(b));
    }

    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const ba = try coerceToBigDecimal(rt, a);
        const bb = try coerceToBigDecimal(rt, b);
        // A `with-precision` binding rounds the quotient to that many significant
        // figures (HALF_UP); else exact (raises on a non-terminating expansion). D-467.
        if (mathContext(rt)) |mc| {
            if (mc.precision > 0)
                return try big_decimal_mod.allocDivPrecision(rt, ba, bb, mc.precision, mc.mode);
        }
        return try big_decimal_mod.allocDiv(rt, ba, bb);
    }

    if (a.tag() == .ratio or b.tag() == .ratio) {
        return try ratioArith(rt, a, b, .div);
    }

    // PERF: both immediate integers → pure i64 division (ADR-0149): a small
    // reduced ratio (no Managed/arena/BigInt) or an exact i64 quotient. The
    // `(/ 1 x)` harmonic-sum hot path lands here. Both are i48 (≠ MIN_I64).
    if (a.tag() == .integer and b.tag() == .integer) {
        const ai = @as(i64, a.asInteger());
        const bi = @as(i64, b.asInteger());
        if (bi == 0) return error.DivideByZero;
        if (try ratio_mod.allocFromI64Pair(rt, ai, bi)) |r| return r;
        // exact integer quotient — Long category (both operands Long), `(/ 6 3)`→2.
        return try wrapI64(rt, @divTrunc(ai, bi));
    }

    var am = try coerceToManaged(rt, a);
    defer am.deinit();
    var bm = try coerceToManaged(rt, b);
    defer bm.deinit();
    return divideIntegers(rt, &am, &bm, isTrueBigInt(a) or isTrueBigInt(b));
}

/// clj's `Numbers.divide` over two exact integers: a reduced Ratio, or the exact
/// quotient when the denominator divides the numerator. `bigint_operand` says
/// whether either operand is a BigInt (D-165 origin `.bigint`). Two Longs take
/// clj's LongOps arm, whose quotient is a Long, unless one of them is
/// Long/MIN_VALUE, which LongOps hands to BigIntOps; any BigIntOps quotient is a
/// BigInt however small (`(/ 6N 3)` is 2N). Raises `error.DivideByZero` on a
/// zero `den`. Shared by `/` and the `n/d` ratio literal, so the two agree.
pub fn divideIntegers(rt: *Runtime, num: *const Managed, den: *const Managed, bigint_operand: bool) !Value {
    if (try ratio_mod.allocFromManagedPair(rt, num, den)) |r| return r;
    // `allocFromManagedPair` answers null without reducing the caller's pair,
    // so the collapsed value is the quotient, not `num`.
    var q = try Managed.init(rt.gc.infra);
    defer q.deinit();
    var rem = try Managed.init(rt.gc.infra);
    defer rem.deinit();
    try q.divTrunc(&rem, num, den);
    const long_ops = !bigint_operand and !isMinLong(num) and !isMinLong(den);
    if (long_ops) return try wrapManaged(rt, &q);
    return try big_int.allocFromManaged(rt, &q, .bigint);
}

fn isMinLong(m: *const Managed) bool {
    const x = m.toInt(i64) catch return false;
    return x == std.math.minInt(i64);
}

/// Three-way order of two f64 that maps a NaN operand to `.eq`
/// (the clojure.core/compare rule). Shared by every numeric-tower
/// ordering site: `valueCompare`'s float arm + `numSign`.
pub fn floatOrder(a: f64, b: f64) std.math.Order {
    if (std.math.isNan(a) or std.math.isNan(b)) return .eq;
    return std.math.order(a, b);
}

/// Exact sign of a numeric Value: `.lt` (negative) / `.eq` (zero) /
/// `.gt` (positive). Used by `modPromoting`'s floor-mod correction.
/// Exact (no float round-off) for the integer / BigInt / Ratio cases;
/// the float arm reads the f64 sign directly.
fn numSign(v: Value) std.math.Order {
    return switch (v.tag()) {
        .integer => std.math.order(@as(i64, v.asInteger()), 0),
        .char => std.math.order(@as(i64, v.asChar()), 0),
        .float => floatOrder(v.asFloat(), 0),
        .big_int => big_int.asManaged(v).toConst().orderAgainstScalar(0),
        .ratio => switch (ratio_mod.parts(v)) {
            .small => |s| std.math.order(s.n, 0),
            .big => |b| b.n.m.toConst().orderAgainstScalar(0),
        },
        .big_decimal => v.decodePtr(*const big_decimal_mod.BigDecimal).unscaled.m.toConst().orderAgainstScalar(0),
        else => .eq,
    };
}

/// Total order of two numerics ACROSS the whole tower (the D-014a combine
/// ladder, done exactly): the sign of their tower-promoting difference. Float
/// contagion matches clj (`(compare 1N 1.0)`→0 because the diff is the float
/// 0.0); a no-float mix compares EXACTLY (no f64 round-off, so
/// `(compare (inc 10^30N) 10^30N)`→1). Caller guarantees both are numeric.
/// `compare.zig`'s cross-category arm delegates here (replacing a lossy f64
/// collapse that raised on ratio / BigDecimal / BigInt mixes).
pub fn orderNumeric(rt: *Runtime, a: Value, b: Value) !std.math.Order {
    return numSign(try subPromoting(rt, a, b));
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
        const bd = try toF64(b);
        if (bd == 0) return error.DivideByZero;
        return Value.initFloat(@trunc(try toF64(a) / bd));
    }
    if (a.tag() == .big_decimal or b.tag() == .big_decimal) {
        const ba = try coerceToBigDecimal(rt, a);
        const bb = try coerceToBigDecimal(rt, b);
        return try big_decimal_mod.allocQuotient(rt, ba, bb);
    }

    // Exact path (Long / BigInt / Ratio). a/b = (an*bd)/(ad*bn); the
    // truncated quotient is divTrunc of that cross-multiplied fraction.
    var owned_a: OwnedParts = .{};
    defer owned_a.deinit();
    const ap = try partsOf(rt, a, &owned_a);
    var owned_b: OwnedParts = .{};
    defer owned_b.deinit();
    const bp = try partsOf(rt, b, &owned_b);

    var numer = try Managed.init(rt.gc.infra);
    defer numer.deinit();
    var denom = try Managed.init(rt.gc.infra);
    defer denom.deinit();
    try numer.mul(ap.num, bp.den);
    try denom.mul(ap.den, bp.num);
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
        .ratio => switch (ratio_mod.parts(v)) {
            // small: |n/d| <= |n| < 2^63, so the quotient is an exact i64.
            .small => |s| return @divTrunc(s.n, s.d),
            .big => return ownedToI64(try truncToManaged(rt, v)),
        },
        .big_decimal => return ownedToI64(try truncToManaged(rt, v)),
        else => return error.NotANumber,
    }
}

/// The integer part of an exact numeric Value, truncated toward zero, at any
/// width: clj's `Ratio.bigIntegerValue` and `BigDecimal.toBigInteger`, which
/// `bigint` and `biginteger` answer (`(bigint 24691357802469135781/2)` is
/// 12345678901234567890N). `error.NotANumber` for a float, which has no exact
/// integer part here (`bigint` takes a double through a BigDecimal first, as
/// clj does), or for a non-numeric tag. The caller owns the result.
pub fn truncToManaged(rt: *Runtime, v: Value) !Managed {
    const infra = rt.gc.infra;
    switch (v.tag()) {
        .integer => return Managed.initSet(infra, @as(i64, v.asInteger())),
        .char => return Managed.initSet(infra, @as(i64, v.asChar())),
        .big_int => return big_int.asManaged(v).cloneWithDifferentAllocator(infra),
        .ratio => switch (ratio_mod.parts(v)) {
            .small => |s| return Managed.initSet(infra, @divTrunc(s.n, s.d)),
            .big => |b| return truncQuotient(rt, b.n.m, b.d.m),
        },
        .big_decimal => {
            // value = unscaled * 10^(-scale): divTrunc by 10^scale for a
            // positive scale, an exact multiply for a negative one.
            const bd = v.decodePtr(*const big_decimal_mod.BigDecimal);
            var u = try bd.unscaled.m.cloneWithDifferentAllocator(infra);
            if (bd.scale == 0) return u;
            defer u.deinit();
            var pow = try tenPow(rt, if (bd.scale < 0) -bd.scale else bd.scale);
            defer pow.deinit();
            if (bd.scale > 0) return truncQuotient(rt, &u, &pow);
            var p = try Managed.init(infra);
            errdefer p.deinit();
            try p.mul(&u, &pow);
            return p;
        },
        else => return error.NotANumber,
    }
}

/// `n / d` truncated toward zero, as an owned Managed.
fn truncQuotient(rt: *Runtime, n: *const Managed, d: *const Managed) !Managed {
    var q = try Managed.init(rt.gc.infra);
    errdefer q.deinit();
    var r = try Managed.init(rt.gc.infra);
    defer r.deinit();
    try q.divTrunc(&r, n, d);
    return q;
}

/// `m` as an i64, or `error.OutOfRange`; takes ownership of `m`.
fn ownedToI64(m: Managed) error{OutOfRange}!i64 {
    var owned = m;
    defer owned.deinit();
    return owned.toInt(i64) catch error.OutOfRange;
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

test "divideIntegers: LongOps quotient is a Long; MIN_VALUE or a BigInt operand makes a BigInt" {
    var fix = Fixture.init();
    defer fix.deinit();

    var n = try Managed.initSet(testing.allocator, @as(i64, 1) << 55);
    defer n.deinit();
    var d = try Managed.initSet(testing.allocator, 2);
    defer d.deinit();
    const long_q = try divideIntegers(&fix.rt, &n, &d, false);
    try testing.expect(long_q.tag() == .big_int);
    try testing.expect(big_int.originOf(long_q) == .long);
    try testing.expectEqual(@as(i64, 1) << 54, try big_int.asManaged(long_q).toInt(i64));

    const big_q = try divideIntegers(&fix.rt, &n, &d, true);
    try testing.expect(big_int.originOf(big_q) == .bigint);

    try n.set(std.math.minInt(i64));
    try d.set(1);
    const min_q = try divideIntegers(&fix.rt, &n, &d, false);
    try testing.expect(min_q.tag() == .big_int);
    try testing.expect(big_int.originOf(min_q) == .bigint);
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), try big_int.asManaged(min_q).toInt(i64));

    try d.set(0);
    try testing.expectError(error.DivideByZero, divideIntegers(&fix.rt, &n, &d, false));
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

test "floatOrder maps a NaN operand to .eq (no std.math.order unreachable)" {
    const nan = std.math.nan(f64);
    try testing.expectEqual(std.math.Order.eq, floatOrder(nan, 1.0));
    try testing.expectEqual(std.math.Order.eq, floatOrder(1.0, nan));
    try testing.expectEqual(std.math.Order.eq, floatOrder(nan, nan));
    try testing.expectEqual(std.math.Order.lt, floatOrder(1.0, 2.0));
    try testing.expectEqual(std.math.Order.gt, floatOrder(2.0, 1.0));
    try testing.expectEqual(std.math.Order.eq, floatOrder(1.0, 1.0));
}

test "modPromoting with a NaN operand yields NaN, never a numSign panic" {
    var fix = Fixture.init();
    defer fix.deinit();
    const nan = Value.initFloat(std.math.nan(f64));
    const md = try modPromoting(&fix.rt, nan, Value.initInteger(3));
    try testing.expect(md.isFloat() and std.math.isNan(md.asFloat()));
    const mv = try modPromoting(&fix.rt, Value.initInteger(3), nan);
    try testing.expect(mv.isFloat() and std.math.isNan(mv.asFloat()));
}
