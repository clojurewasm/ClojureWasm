// SPDX-License-Identifier: EPL-2.0
//! Arbitrary-precision BigDecimal per F-005 + ADR-0027 §2 Group D
//! slot 2.
//!
//! BigDecimal = (unscaled: *BigInt, scale: i32). Numeric value is
//! `unscaled * 10^(-scale)`. Mirrors JVM `java.math.BigDecimal`:
//!
//!   - `unscaled` is the integer significand, stored as a GC-managed
//!     BigInt (so the trace fn marks it; the BigInt carries its own
//!     finaliser).
//!   - `scale` is the decimal point's offset from the right of the
//!     unscaled integer. Positive scale = fractional value
//!     (`scale=2, unscaled=150` → 1.50). Negative scale = trailing
//!     zeros (`scale=-2, unscaled=15` → 1500).
//!
//! Exact arithmetic (add / sub / mul / div / quotient / compare) is
//! landed (see the `alloc*` / `compareValue` functions below), as is
//! reader-literal entry (`1.5M` → BigDecimal). MathContext-driven
//! rounded division (explicit rounding modes) is not yet wired —
//! `allocDiv` currently produces the exact rational result.
//!
//! HeapTag slot 50 (Group D position 2, `big_decimal`) per F-004 +
//! ADR-0027.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const HeapHeader = value_mod.HeapHeader;
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const big_int_mod = @import("big_int.zig");
const BigInt = big_int_mod.BigInt;

/// GC-managed BigDecimal. Wraps a `*BigInt` significand and an i32
/// decimal-point offset. `unscaled` itself is GC-managed; this
/// struct's trace fn keeps it alive.
pub const BigDecimal = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// AUTHORITATIVE value (mirrors java.math.BigDecimal): print,
    /// arithmetic result-scale, and any scale accessor read this pair.
    unscaled: *BigInt,
    scale: i32,
    /// Stripped-trailing-zeros projection (ADR-0077 / D-205): the
    /// Clojure scale-INDEPENDENT key/hash view, computed once at
    /// construction. `keyEqValue` / `valueHash` read this so `1.5M` and
    /// `1.50M` are interchangeable map keys (rt-free, like Ratio's
    /// canonical fields). NEVER read for print / arithmetic.
    norm_scale: i32,
    norm_unscaled: *BigInt,

    comptime {
        std.debug.assert(@alignOf(BigDecimal) >= 8);
        std.debug.assert(@offsetOf(BigDecimal, "header") == 0);
        // unscaled lands at the same offset as BigInt.m so the two
        // BigInt-backed numeric heap structs share the trailing-pad pattern.
        // (Ratio is now a two-tier inline-i64/big union, ADR-0149 — no longer
        // a fixed *BigInt pair, so it is not part of this offset family.)
        std.debug.assert(@offsetOf(BigDecimal, "unscaled") == @offsetOf(BigInt, "m"));
    }
};

/// Build the stripped-trailing-zeros projection of `(unscaled, scale)`:
/// repeatedly divide the unscaled by 10 while it divides evenly, lowering
/// the scale in step; a zero unscaled normalises to `(0, 0)`. Returns the
/// normalised unscaled as a fresh GC BigInt Value plus the normalised
/// scale. Allocates (construction-time only — `rt` is present); the
/// resulting fields make the rt-free key/hash compare possible (ADR-0077).
fn buildNormalized(rt: *Runtime, unscaled: *const std.math.big.int.Managed, scale: i32) !struct { unscaled: Value, scale: i32 } {
    const infra = rt.gc.infra;
    var n = try unscaled.cloneWithDifferentAllocator(infra);
    defer n.deinit();
    var norm_scale = scale;
    if (n.eqlZero()) {
        norm_scale = 0;
    } else {
        var ten = try std.math.big.int.Managed.initSet(infra, 10);
        defer ten.deinit();
        var q = try std.math.big.int.Managed.init(infra);
        defer q.deinit();
        var r = try std.math.big.int.Managed.init(infra);
        defer r.deinit();
        while (true) {
            try q.divTrunc(&r, &n, &ten);
            if (!r.eqlZero()) break;
            n.swap(&q);
            norm_scale -= 1;
        }
    }
    const norm_unscaled = try big_int_mod.allocFromManaged(rt, &n, .bigint);
    return .{ .unscaled = norm_unscaled, .scale = norm_scale };
}

/// Allocate a BigDecimal from an i64 unscaled value + i32 scale.
pub fn allocFromI64Scale(rt: *Runtime, unscaled_i64: i64, scale: i32) !Value {
    var u_m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer u_m.deinit();
    try u_m.set(unscaled_i64);
    return allocFromManagedScale(rt, &u_m, scale);
}

/// Allocate a BigDecimal from a caller-built Managed unscaled
/// value + i32 scale. The caller retains ownership of the input
/// (this routine clones onto `rt.gc.infra` via `allocFromManaged`).
pub fn allocFromManagedScale(
    rt: *Runtime,
    unscaled: *const std.math.big.int.Managed,
    scale: i32,
) !Value {
    const unscaled_val = try big_int_mod.allocFromManaged(rt, unscaled, .bigint);
    const norm = try buildNormalized(rt, unscaled, scale);

    const bd = try rt.gc.alloc(BigDecimal);
    bd.* = .{
        .header = HeapHeader.init(.big_decimal),
        .unscaled = unscaled_val.decodePtr(*BigInt),
        .scale = scale,
        .norm_scale = norm.scale,
        .norm_unscaled = norm.unscaled.decodePtr(*BigInt),
    };
    return Value.encodeHeapPtr(.big_decimal, bd);
}

/// Exact BigDecimal of a rational `numer/denom` (`denom ≠ 0`; need not be
/// reduced), or `error.NonTerminatingDecimal` when the decimal expansion does
/// not terminate. The pair is gcd-reduced and sign-normalised (denom > 0)
/// first, then — since a reduced `n/d` terminates iff `d = 2^a · 5^b` —
/// `scale = max(a, b)` and the unscaled integer is `n · 5^(a−b)` (a ≥ b) or
/// `n · 2^(b−a)` (b > a). Shared by `clojure.core/bigdec` (a ratio arg) and
/// BigDecimal `÷` contagion. JVM ref: `BigDecimal(n).divide(BigDecimal(d))`.
pub fn allocFromRatioParts(
    rt: *Runtime,
    numer: *const std.math.big.int.Managed,
    denom: *const std.math.big.int.Managed,
) !Value {
    const infra = rt.gc.infra;
    if (denom.eqlZero()) return error.DivideByZero;

    // gcd-reduce and force denom > 0 (sign rides the numerator) so the 2/5
    // termination test below sees the genuine reduced denominator.
    var g = try std.math.big.int.Managed.init(infra);
    defer g.deinit();
    try g.gcd(numer, denom);
    var n = try std.math.big.int.Managed.init(infra);
    defer n.deinit();
    var d = try std.math.big.int.Managed.init(infra);
    defer d.deinit();
    var rscratch = try std.math.big.int.Managed.init(infra);
    defer rscratch.deinit();
    try n.divTrunc(&rscratch, numer, &g);
    try d.divTrunc(&rscratch, denom, &g);
    if (!d.isPositive()) {
        n.negate();
        d.negate();
    }

    var q = try std.math.big.int.Managed.init(infra);
    defer q.deinit();
    var rmd = try std.math.big.int.Managed.init(infra);
    defer rmd.deinit();
    var two = try std.math.big.int.Managed.initSet(infra, 2);
    defer two.deinit();
    var five = try std.math.big.int.Managed.initSet(infra, 5);
    defer five.deinit();

    var a: u32 = 0;
    while (true) {
        try q.divTrunc(&rmd, &d, &two);
        if (!rmd.eqlZero()) break;
        d.swap(&q);
        a += 1;
    }
    var b: u32 = 0;
    while (true) {
        try q.divTrunc(&rmd, &d, &five);
        if (!rmd.eqlZero()) break;
        d.swap(&q);
        b += 1;
    }
    if (d.toConst().orderAgainstScalar(1) != .eq)
        return error.NonTerminatingDecimal;

    const scale: i32 = @intCast(@max(a, b));
    var unscaled = try n.clone();
    defer unscaled.deinit();
    if (a != b) {
        var factor = try std.math.big.int.Managed.init(infra);
        defer factor.deinit();
        const base: *std.math.big.int.Managed = if (a > b) &five else &two;
        const exp: u32 = if (a > b) a - b else b - a;
        try factor.pow(base, exp);
        var prod = try std.math.big.int.Managed.init(infra);
        defer prod.deinit();
        try prod.mul(&unscaled, &factor);
        unscaled.swap(&prod);
    }
    return allocFromManagedScale(rt, &unscaled, scale);
}

/// The two BigDecimals `a, b` as an exact rational `n/d` with the decimal
/// points cleared: `a/b = (ua·10^−sa)/(ub·10^−sb) = (ua·10^max(0,sb−sa)) /
/// (ub·10^max(0,sa−sb))`. Caller owns and must `deinit` both Manageds.
const AlignedRational = struct { n: std.math.big.int.Managed, d: std.math.big.int.Managed };

fn alignedRational(rt: *Runtime, a: Value, b: Value) !AlignedRational {
    const infra = rt.gc.infra;
    var n = try asUnscaled(a).m.clone();
    errdefer n.deinit();
    var d = try asUnscaled(b).m.clone();
    errdefer d.deinit();
    const e: i64 = @as(i64, asScale(b)) - @as(i64, asScale(a)); // a/b = (ua/ub)·10^e
    if (e != 0) {
        var ten = try std.math.big.int.Managed.initSet(infra, 10);
        defer ten.deinit();
        var p = try std.math.big.int.Managed.init(infra);
        defer p.deinit();
        try p.pow(&ten, @intCast(@abs(e)));
        var prod = try std.math.big.int.Managed.init(infra);
        defer prod.deinit();
        if (e > 0) {
            try prod.mul(&n, &p);
            n.swap(&prod);
        } else {
            try prod.mul(&d, &p);
            d.swap(&prod);
        }
    }
    return .{ .n = n, .d = d };
}

/// `a ÷ b` for two BigDecimals → the exact decimal quotient, or
/// `error.NonTerminatingDecimal` / `error.DivideByZero`. JVM ref:
/// `BigDecimal.divide` with no MathContext (exact or ArithmeticException).
pub fn allocDiv(rt: *Runtime, a: Value, b: Value) !Value {
    var ar = try alignedRational(rt, a, b);
    defer {
        ar.n.deinit();
        ar.d.deinit();
    }
    return allocFromRatioParts(rt, &ar.n, &ar.d);
}

/// Integral quotient `a ÷ b` truncated toward zero, as a BigDecimal with scale
/// `max(0, a.scale − b.scale)` (JVM `divideToIntegralValue` preferred scale,
/// floored at 0). `error.DivideByZero` when `b` is zero.
pub fn allocQuotient(rt: *Runtime, a: Value, b: Value) !Value {
    const infra = rt.gc.infra;
    var ar = try alignedRational(rt, a, b);
    defer {
        ar.n.deinit();
        ar.d.deinit();
    }
    if (ar.d.eqlZero()) return error.DivideByZero;
    var q = try std.math.big.int.Managed.init(infra);
    defer q.deinit();
    var r = try std.math.big.int.Managed.init(infra);
    defer r.deinit();
    try q.divTrunc(&r, &ar.n, &ar.d); // toward zero

    const diff: i64 = @as(i64, asScale(a)) - @as(i64, asScale(b));
    const scale: i32 = @intCast(@max(@as(i64, 0), diff));
    if (scale > 0) {
        var ten = try std.math.big.int.Managed.initSet(infra, 10);
        defer ten.deinit();
        var p = try std.math.big.int.Managed.init(infra);
        defer p.deinit();
        try p.pow(&ten, @intCast(scale));
        var prod = try std.math.big.int.Managed.init(infra);
        defer prod.deinit();
        try prod.mul(&q, &p);
        q.swap(&prod);
    }
    return allocFromManagedScale(rt, &q, scale);
}

/// Decimal-digit count of a non-negative Managed (`0` counts as 1 digit).
fn digitCount(infra: std.mem.Allocator, m: *const std.math.big.int.Managed) !usize {
    if (m.eqlZero()) return 1;
    const s = try m.toConst().toStringAlloc(infra, 10, .lower);
    defer infra.free(s);
    return if (s.len > 0 and s[0] == '-') s.len - 1 else s.len;
}

/// q = trunc(n·10^s / d), r = remainder, for n,d > 0. `s` may be negative (then
/// the divisor is scaled instead of the dividend). `ten`/`scratch` are caller-owned.
fn shiftedDivTrunc(infra: std.mem.Allocator, q: *std.math.big.int.Managed, r: *std.math.big.int.Managed, n: *const std.math.big.int.Managed, d: *const std.math.big.int.Managed, ten: *const std.math.big.int.Managed, s: i64) !void {
    var pow10 = try std.math.big.int.Managed.init(infra);
    defer pow10.deinit();
    try pow10.pow(ten, @intCast(@abs(s)));
    if (s >= 0) {
        var num = try std.math.big.int.Managed.init(infra);
        defer num.deinit();
        try num.mul(n, &pow10);
        try q.divTrunc(r, &num, d);
    } else {
        var den = try std.math.big.int.Managed.init(infra);
        defer den.deinit();
        try den.mul(d, &pow10);
        try q.divTrunc(r, n, &den);
    }
}

/// `a ÷ b` rounded to `precision` significant figures, HALF_UP — clj's
/// `with-precision` default (BigDecimal.divide with a MathContext). D-467.
pub fn allocDivPrecision(rt: *Runtime, a: Value, b: Value, precision: u32) !Value {
    const infra = rt.gc.infra;
    // clj's MathContext divide treats `precision` as a MAXIMUM: an exact quotient
    // that terminates within `precision` significant figures keeps its natural
    // (un-padded) form — `(with-precision 4 (/ 1M 8))` → 0.125M, not 0.1250M. So try
    // the exact divide first; round only when it does not terminate OR exceeds the
    // precision.
    if (allocDiv(rt, a, b)) |exact| {
        if ((try digitCount(infra, asUnscaled(exact).m)) <= precision) return exact;
    } else |err| switch (err) {
        error.NonTerminatingDecimal => {},
        else => return err,
    }
    var ar = try alignedRational(rt, a, b);
    defer {
        ar.n.deinit();
        ar.d.deinit();
    }
    if (ar.d.eqlZero()) return error.DivideByZero;
    if (ar.n.eqlZero()) {
        var z = try std.math.big.int.Managed.initSet(infra, 0);
        defer z.deinit();
        return allocFromManagedScale(rt, &z, 0);
    }
    const result_neg = ar.n.isPositive() != ar.d.isPositive();
    // Work with |n|, |d|.
    var n = try std.math.big.int.Managed.init(infra);
    defer n.deinit();
    try n.copy(ar.n.toConst().abs());
    var d = try std.math.big.int.Managed.init(infra);
    defer d.deinit();
    try d.copy(ar.d.toConst().abs());
    var ten = try std.math.big.int.Managed.initSet(infra, 10);
    defer ten.deinit();

    // Guess the shift s so q = trunc(n·10^s/d) has `precision` digits, then adjust.
    const dn = try digitCount(infra, &n);
    const dd = try digitCount(infra, &d);
    var s: i64 = @as(i64, @intCast(precision)) - @as(i64, @intCast(dn)) + @as(i64, @intCast(dd));
    var q = try std.math.big.int.Managed.init(infra);
    defer q.deinit();
    var r = try std.math.big.int.Managed.init(infra);
    defer r.deinit();
    while (true) {
        try shiftedDivTrunc(infra, &q, &r, &n, &d, &ten, s);
        const dq = try digitCount(infra, &q);
        if (!q.eqlZero() and dq > precision) {
            s -= 1;
        } else if (q.eqlZero() or dq < precision) {
            s += 1;
        } else break;
    }
    // HALF_UP: round away from zero iff 2·r ≥ the EFFECTIVE divisor. For s ≥ 0 the
    // divisor was `d`; for s < 0 the dividend was left alone and the divisor scaled
    // to `d·10^|s|`, so `r` is a remainder w.r.t. that scaled divisor — comparing
    // against the bare `d` over-rounds large-magnitude quotients (D-467).
    var eff_d = try std.math.big.int.Managed.init(infra);
    defer eff_d.deinit();
    if (s >= 0) {
        try eff_d.copy(d.toConst());
    } else {
        var p10 = try std.math.big.int.Managed.init(infra);
        defer p10.deinit();
        try p10.pow(&ten, @intCast(@abs(s)));
        try eff_d.mul(&d, &p10);
    }
    var r2 = try std.math.big.int.Managed.init(infra);
    defer r2.deinit();
    var two = try std.math.big.int.Managed.initSet(infra, 2);
    defer two.deinit();
    try r2.mul(&r, &two);
    if (r2.toConst().order(eff_d.toConst()) != .lt) {
        var one = try std.math.big.int.Managed.initSet(infra, 1);
        defer one.deinit();
        try q.add(&q, &one);
        // A carry can grow q by a digit (999→1000): drop the trailing 0, s -= 1.
        if ((try digitCount(infra, &q)) > precision) {
            var qd = try std.math.big.int.Managed.init(infra);
            defer qd.deinit();
            var rem = try std.math.big.int.Managed.init(infra);
            defer rem.deinit();
            try qd.divTrunc(&rem, &q, &ten);
            q.swap(&qd);
            s -= 1;
        }
    }
    if (result_neg) q.negate();
    return allocFromManagedScale(rt, &q, @intCast(s));
}

/// Decode a BigDecimal Value into its unscaled significand.
pub fn asUnscaled(v: Value) *const BigInt {
    std.debug.assert(v.tag() == .big_decimal);
    return v.decodePtr(*const BigDecimal).unscaled;
}

/// Decode a BigDecimal Value into its decimal-point scale offset.
pub fn asScale(v: Value) i32 {
    std.debug.assert(v.tag() == .big_decimal);
    return v.decodePtr(*const BigDecimal).scale;
}

/// Convert to the nearest f64 (`unscaled * 10^-scale`). Shared by the numeric
/// `double`/`float` coercion (math.zig) and `format`'s %f/%e/%g conversions
/// (F-011 DRY). Lossy beyond f64 range/precision, matching JVM
/// `BigDecimal.doubleValue`.
pub fn toFloat(v: Value) f64 {
    const unscaled = asUnscaled(v).m.toFloat(f64, .nearest_even)[0];
    return unscaled * std.math.pow(f64, 10.0, -@as(f64, @floatFromInt(asScale(v))));
}

/// The stripped-trailing-zeros unscaled significand (ADR-0077): the
/// scale-independent key/hash projection. NOT the print/arithmetic value.
pub fn asNormUnscaled(v: Value) *const BigInt {
    std.debug.assert(v.tag() == .big_decimal);
    return v.decodePtr(*const BigDecimal).norm_unscaled;
}

/// The stripped scale paired with `asNormUnscaled` (ADR-0077).
pub fn asNormScale(v: Value) i32 {
    std.debug.assert(v.tag() == .big_decimal);
    return v.decodePtr(*const BigDecimal).norm_scale;
}

/// Trace fn called by the mark phase. Walks `unscaled` so the
/// underlying BigInt + its *Managed limbs stay alive across GC
/// cycles. BigDecimal itself has no non-GC owned resources.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const bd: *BigDecimal = @ptrCast(@alignCast(header));
    mark_sweep.mark(gc, &bd.unscaled.header);
    // The cached normalized projection (ADR-0077) is GC-managed too.
    mark_sweep.mark(gc, &bd.norm_unscaled.header);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.big_decimal, &traceGc);
}

// --- same-type arithmetic ---
//
// BigDecimal add/sub/compare align both operands to the larger
// scale by multiplying the smaller-scale unscaled value by
// 10^(scale_diff). `mul` multiplies unscaled values and sums
// scales (JVM convention; no precision loss). `allocDiv` produces the
// exact rational result; MathContext-driven rounded division
// (explicit rounding mode + precision) is not yet wired.

/// Three-way compare two BigDecimal Values. Aligns scales then
/// compares unscaled values. Both inputs MUST have
/// `tag() == .big_decimal`.
pub fn compareValue(rt: *Runtime, a: Value, b: Value) !std.math.Order {
    std.debug.assert(a.tag() == .big_decimal and b.tag() == .big_decimal);
    var aligned_a: std.math.big.int.Managed = undefined;
    var aligned_b: std.math.big.int.Managed = undefined;
    try alignScales(rt, a, b, &aligned_a, &aligned_b);
    defer aligned_a.deinit();
    defer aligned_b.deinit();
    return aligned_a.order(aligned_b);
}

/// `a + b` returning a fresh BigDecimal with `scale = max(a.scale, b.scale)`.
pub fn allocAdd(rt: *Runtime, a: Value, b: Value) !Value {
    return try alignedCombine(rt, a, b, .add);
}

/// `a - b`.
pub fn allocSub(rt: *Runtime, a: Value, b: Value) !Value {
    return try alignedCombine(rt, a, b, .sub);
}

/// `a * b` — unscaled values multiply, scales add.
pub fn allocMul(rt: *Runtime, a: Value, b: Value) !Value {
    std.debug.assert(a.tag() == .big_decimal and b.tag() == .big_decimal);
    const ad = a.decodePtr(*const BigDecimal);
    const bd = b.decodePtr(*const BigDecimal);

    var u = try std.math.big.int.Managed.init(rt.gc.infra);
    defer u.deinit();
    try u.mul(ad.unscaled.m, bd.unscaled.m);

    return try allocFromManagedScale(rt, &u, ad.scale + bd.scale);
}

/// `(.setScale bd newScale roundingMode)` — return a BigDecimal of the given
/// scale, rounding per the JVM `ROUND_*` int constant (UP=0 DOWN=1 CEILING=2
/// FLOOR=3 HALF_UP=4 HALF_DOWN=5 HALF_EVEN=6 UNNECESSARY=7). `newScale >= scale`
/// pads exactly (unscaled·10^Δ, no rounding); a smaller scale divides the
/// unscaled by 10^Δ and the dropped remainder drives the mode. `v` MUST be a
/// `.big_decimal`. `error.RoundingNecessary` when mode is UNNECESSARY but the
/// drop is non-zero; `error.InvalidRoundingMode` for an out-of-range mode.
pub fn setScale(rt: *Runtime, v: Value, new_scale: i32, mode: i64) !Value {
    std.debug.assert(v.tag() == .big_decimal);
    const Managed = std.math.big.int.Managed;
    const bd = v.decodePtr(*const BigDecimal);
    const infra = rt.gc.infra;

    var unscaled = try bd.unscaled.m.clone();
    defer unscaled.deinit();

    if (new_scale >= bd.scale) {
        const diff: u32 = @intCast(new_scale - bd.scale);
        if (diff != 0) {
            var ten = try Managed.initSet(infra, 10);
            defer ten.deinit();
            var factor = try Managed.init(infra);
            defer factor.deinit();
            try factor.pow(&ten, diff);
            var prod = try Managed.init(infra);
            defer prod.deinit();
            try prod.mul(&unscaled, &factor);
            unscaled.swap(&prod);
        }
        return allocFromManagedScale(rt, &unscaled, new_scale);
    }

    const drop: u32 = @intCast(bd.scale - new_scale);
    var ten = try Managed.initSet(infra, 10);
    defer ten.deinit();
    var divisor = try Managed.init(infra);
    defer divisor.deinit();
    try divisor.pow(&ten, drop);

    var q = try Managed.init(infra);
    defer q.deinit();
    var r = try Managed.init(infra);
    defer r.deinit();
    try q.divTrunc(&r, &unscaled, &divisor); // q toward zero; sign(r) = sign(unscaled)

    if (r.toConst().orderAgainstScalar(0) != .eq) {
        const r_neg = r.toConst().orderAgainstScalar(0) == .lt;
        // 2·|r| vs |divisor| decides the HALF_* tie; divisor is always positive.
        var abs_r = try r.clone();
        defer abs_r.deinit();
        abs_r.abs();
        var two_abs = try Managed.init(infra);
        defer two_abs.deinit();
        try two_abs.add(&abs_r, &abs_r);
        const half = two_abs.order(divisor); // .lt below half / .eq exactly half / .gt above

        const round_away = switch (mode) {
            0 => true, // UP — always away from zero
            1 => false, // DOWN — always toward zero (truncate)
            2 => !r_neg, // CEILING — toward +inf
            3 => r_neg, // FLOOR — toward -inf
            4 => half != .lt, // HALF_UP — tie rounds away
            5 => half == .gt, // HALF_DOWN — tie rounds toward zero
            6 => half == .gt or (half == .eq and (q.toConst().limbs[0] & 1) == 1), // HALF_EVEN
            7 => return error.RoundingNecessary, // UNNECESSARY with a remainder
            else => return error.InvalidRoundingMode,
        };
        if (round_away) {
            var one = try Managed.initSet(infra, 1);
            defer one.deinit();
            if (r_neg) try q.sub(&q, &one) else try q.add(&q, &one);
        }
    }
    return allocFromManagedScale(rt, &q, new_scale);
}

const AddOrSub = enum { add, sub };

fn alignedCombine(rt: *Runtime, a: Value, b: Value, op: AddOrSub) !Value {
    std.debug.assert(a.tag() == .big_decimal and b.tag() == .big_decimal);
    const ad = a.decodePtr(*const BigDecimal);
    const bd = b.decodePtr(*const BigDecimal);

    var aligned_a: std.math.big.int.Managed = undefined;
    var aligned_b: std.math.big.int.Managed = undefined;
    try alignScales(rt, a, b, &aligned_a, &aligned_b);
    defer aligned_a.deinit();
    defer aligned_b.deinit();

    var r = try std.math.big.int.Managed.init(rt.gc.infra);
    defer r.deinit();
    switch (op) {
        .add => try r.add(&aligned_a, &aligned_b),
        .sub => try r.sub(&aligned_a, &aligned_b),
    }

    const result_scale = @max(ad.scale, bd.scale);
    return try allocFromManagedScale(rt, &r, result_scale);
}

/// Initialise `aligned_a` / `aligned_b` such that both represent
/// the same numeric values with the common scale `max(a.scale, b.scale)`.
/// Caller MUST `deinit` both outputs.
fn alignScales(
    rt: *Runtime,
    a: Value,
    b: Value,
    aligned_a: *std.math.big.int.Managed,
    aligned_b: *std.math.big.int.Managed,
) !void {
    const ad = a.decodePtr(*const BigDecimal);
    const bd = b.decodePtr(*const BigDecimal);
    const target_scale = @max(ad.scale, bd.scale);

    aligned_a.* = try cloneAndScale(rt, ad.unscaled.m, target_scale - ad.scale);
    errdefer aligned_a.deinit();
    aligned_b.* = try cloneAndScale(rt, bd.unscaled.m, target_scale - bd.scale);
}

/// Clone `src` and multiply by 10^extra_scale (extra_scale >= 0).
fn cloneAndScale(rt: *Runtime, src: *const std.math.big.int.Managed, extra_scale: i32) !std.math.big.int.Managed {
    var out = try src.cloneWithDifferentAllocator(rt.gc.infra);
    errdefer out.deinit();
    if (extra_scale > 0) {
        var ten = try std.math.big.int.Managed.init(rt.gc.infra);
        defer ten.deinit();
        try ten.set(10);
        var multiplier = try std.math.big.int.Managed.init(rt.gc.infra);
        defer multiplier.deinit();
        try multiplier.set(1);
        var i: i32 = 0;
        while (i < extra_scale) : (i += 1) {
            var tmp = try std.math.big.int.Managed.init(rt.gc.infra);
            defer tmp.deinit();
            try tmp.mul(&multiplier, &ten);
            multiplier.swap(&tmp);
        }
        var product = try std.math.big.int.Managed.init(rt.gc.infra);
        defer product.deinit();
        try product.mul(&out, &multiplier);
        out.swap(&product);
    }
    return out;
}

// --- tests ---

const testing = std.testing;

const BdFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() BdFixture {
        var fix: BdFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *BdFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "BigDecimal extern struct layout matches the numeric trailing-pad pattern" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(BigDecimal, "header"));
    try testing.expectEqual(@offsetOf(BigInt, "m"), @offsetOf(BigDecimal, "unscaled"));
    try testing.expect(@alignOf(BigDecimal) >= 8);
}

test "allocFromI64Scale (150, 2) represents 1.50 — accessors round-trip" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const v = try allocFromI64Scale(&fix.rt, 150, 2);
    try testing.expect(v.tag() == .big_decimal);
    try testing.expectEqual(@as(i64, 150), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(v))).toInt(i64));
    try testing.expectEqual(@as(i32, 2), asScale(v));
}

test "allocFromI64Scale (15, -2) represents 1500 — negative scale supported" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const v = try allocFromI64Scale(&fix.rt, 15, -2);
    try testing.expectEqual(@as(i64, 15), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(v))).toInt(i64));
    try testing.expectEqual(@as(i32, -2), asScale(v));
}

test "allocFromManagedScale supports unscaled > i64 (2^70 with scale=5)" {
    var fix = BdFixture.init();
    defer fix.deinit();

    var big = try std.math.big.int.Managed.init(testing.allocator);
    defer big.deinit();
    try big.set(1);
    try big.shiftLeft(&big, 70);

    const v = try allocFromManagedScale(&fix.rt, &big, 5);
    try testing.expect(big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(v))).bitCountAbs() > 64);
    try testing.expectEqual(@as(i32, 5), asScale(v));
}

test "compareValue (1.50 vs 1.5): equal numerically despite different scale" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 150, 2); // 1.50
    const b = try allocFromI64Scale(&fix.rt, 15, 1);  // 1.5
    try testing.expectEqual(std.math.Order.eq, try compareValue(&fix.rt, a, b));
}

test "compareValue (1.5 vs 2.0): lt" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 15, 1);
    const b = try allocFromI64Scale(&fix.rt, 20, 1);
    try testing.expectEqual(std.math.Order.lt, try compareValue(&fix.rt, a, b));
}

test "allocAdd (1.50 + 0.5) = 2.00 (scale 2)" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 150, 2);
    const b = try allocFromI64Scale(&fix.rt, 5, 1);
    const sum = try allocAdd(&fix.rt, a, b);
    // 1.50 + 0.5 = 1.50 + 0.50 = 2.00 -> unscaled=200, scale=2
    try testing.expectEqual(@as(i64, 200), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(sum))).toInt(i64));
    try testing.expectEqual(@as(i32, 2), asScale(sum));
}

test "allocSub (3.00 - 1.5) = 1.50" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 300, 2);
    const b = try allocFromI64Scale(&fix.rt, 15, 1);
    const diff = try allocSub(&fix.rt, a, b);
    try testing.expectEqual(@as(i64, 150), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(diff))).toInt(i64));
    try testing.expectEqual(@as(i32, 2), asScale(diff));
}

test "allocMul (1.5 * 2.0): unscaled=300, scale=2 (= 3.00)" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 15, 1);
    const b = try allocFromI64Scale(&fix.rt, 20, 1);
    const prod = try allocMul(&fix.rt, a, b);
    try testing.expectEqual(@as(i64, 300), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asUnscaled(prod))).toInt(i64));
    try testing.expectEqual(@as(i32, 2), asScale(prod));
}

test "normalized projection strips trailing zeros (1.50 → unscaled 15, scale 1)" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const a = try allocFromI64Scale(&fix.rt, 150, 2); // 1.50
    // authoritative (print/arithmetic) form is preserved
    try testing.expectEqual(@as(i32, 2), asScale(a));
    // normalized (key/hash) form is stripped to (15, 1)
    try testing.expectEqual(@as(i32, 1), asNormScale(a));
    try testing.expectEqual(@as(i64, 15), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, @constCast(asNormUnscaled(a)))).toInt(i64));

    // 1.5M and 1.50M share the SAME normalized projection (scale-independent key)
    const b = try allocFromI64Scale(&fix.rt, 15, 1); // 1.5
    try testing.expectEqual(asNormScale(a), asNormScale(b));
    try testing.expectEqual(std.math.Order.eq, big_int_mod.compareManaged(asNormUnscaled(a).m, asNormUnscaled(b).m));
}

test "normalized projection of zero is (0, 0) regardless of scale" {
    var fix = BdFixture.init();
    defer fix.deinit();

    const z2 = try allocFromI64Scale(&fix.rt, 0, 2); // 0.00
    try testing.expectEqual(@as(i32, 0), asNormScale(z2));
    try testing.expectEqual(@as(i64, 0), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, @constCast(asNormUnscaled(z2)))).toInt(i64));
}

test "Runtime.deinit releases BigDecimal + unscaled BigInt (no leak)" {
    var fix = BdFixture.init();
    _ = try allocFromI64Scale(&fix.rt, 150, 2);
    _ = try allocFromI64Scale(&fix.rt, 1234567, 6);
    fix.deinit();
}
