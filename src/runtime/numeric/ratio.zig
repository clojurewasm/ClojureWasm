// SPDX-License-Identifier: EPL-2.0
//! Arbitrary-precision Ratio per F-005 + ADR-0027 §2 Group D slot 1.
//!
//! Ratio holds two `*BigInt` pointers (numerator + denominator).
//! Both BigInts are themselves `gc.alloc`'d extern structs (see
//! `runtime/numeric/big_int.zig`). The Ratio's trace fn marks both
//! pointers; the BigInts carry their own finaliser that releases
//! their respective `*std.math.big.int.Managed` limbs.
//!
//! Construction guarantees the JVM-Clojure invariants:
//!   - gcd-reduced (no common factors between numer and denom)
//!   - denom strictly positive (negative numerator absorbs the sign)
//!   - integer-collapse signalled by a `null` return (caller wraps
//!     the numerator as a plain BigInt)
//!   - divide-by-zero raised as `error.DivideByZero` (caller maps
//!     to the Clojure-side `divide_by_zero` catalog Code).
//!
//! HeapTag slot 49 (Group D position 1, `ratio`) per F-004 + ADR-0027.

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
const Managed = std.math.big.int.Managed;

/// GC-managed canonical two-tier Ratio (ADR-0149). `is_small == 1` IFF the
/// reduced numerator AND denominator both fit i64 — the CANONICAL invariant: a
/// value's representation is uniquely determined (small whenever it fits, big
/// otherwise), so a small `1/2` and a big `1/2` can never coexist. This is what
/// keeps the rt-free `equal`/`hash` ratio arms correct without an `rt` param:
/// small-vs-big are never equal (a big ratio whose value fit i64 would be small).
///
/// - small (`is_small == 1`): `a` = `@bitCast` i64 numerator, `b` = i64 denom
///   (> 0); NO GC children (trace marks nothing). Allocation-free arithmetic.
/// - big (`is_small == 0`): `a` = `@intFromPtr` of a `*BigInt` numerator, `b` =
///   denom; both are separately `gc.alloc`'d BigInts the trace pass marks.
/// `denom` is always strictly positive after a successful constructor.
pub const Ratio = extern struct {
    header: HeapHeader,
    is_small: u8 = 0,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    a: u64,
    b: u64,

    comptime {
        std.debug.assert(@alignOf(Ratio) >= 8);
        std.debug.assert(@offsetOf(Ratio, "header") == 0);
    }

    /// Small-ratio numerator (caller guarantees `is_small == 1`).
    pub inline fn smallNum(self: *const Ratio) i64 {
        return @bitCast(self.a);
    }
    /// Small-ratio denominator (> 0; caller guarantees `is_small == 1`).
    pub inline fn smallDen(self: *const Ratio) i64 {
        return @bitCast(self.b);
    }
    /// Big-ratio numerator BigInt (caller guarantees `is_small == 0`).
    pub inline fn bigNum(self: *const Ratio) *BigInt {
        return @ptrFromInt(@as(usize, @intCast(self.a)));
    }
    /// Big-ratio denominator BigInt (caller guarantees `is_small == 0`).
    pub inline fn bigDen(self: *const Ratio) *BigInt {
        return @ptrFromInt(@as(usize, @intCast(self.b)));
    }
};

/// Numerator / denominator of a Ratio as a tagged union — the canonical accessor
/// the arithmetic / print / compare paths branch on (ADR-0149). `small` carries
/// inline i64s (no alloc); `big` carries the stored `*const BigInt` pair.
pub const RatioParts = union(enum) {
    small: struct { n: i64, d: i64 },
    big: struct { n: *const BigInt, d: *const BigInt },
};

/// Decode a Ratio Value into its `RatioParts`.
pub fn parts(v: Value) RatioParts {
    std.debug.assert(v.tag() == .ratio);
    const r = v.decodePtr(*const Ratio);
    if (r.is_small == 1) return .{ .small = .{ .n = r.smallNum(), .d = r.smallDen() } };
    return .{ .big = .{ .n = r.bigNum(), .d = r.bigDen() } };
}

/// Errors raised by Ratio constructors. `DivideByZero` is mapped to
/// the catalog Code at the Clojure-side dispatch; the Zig API surface
/// stays narrow.
pub const RatioError = error{DivideByZero} || std.mem.Allocator.Error;

/// Allocate a small (inline-i64) Ratio. Caller guarantees `n`/`d` are already
/// reduced, `d > 0`, `d != 1` (not integer-collapsed), and neither is MIN_I64.
fn allocSmall(rt: *Runtime, n: i64, d: i64) RatioError!Value {
    const r = try rt.gc.alloc(Ratio);
    r.* = .{ .header = HeapHeader.init(.ratio), .is_small = 1, .a = @bitCast(n), .b = @bitCast(d) };
    return Value.encodeHeapPtr(.ratio, r);
}

/// gcd of `|a|`,`|b|` as a positive i64. Caller guarantees neither is MIN_I64
/// (so `@abs` does not overflow). `b != 0`.
fn gcdI64(a: i64, b: i64) i64 {
    var x: u64 = @abs(a);
    var y: u64 = @abs(b);
    while (y != 0) {
        const t = x % y;
        x = y;
        y = t;
    }
    return @intCast(x);
}

/// Allocate a reduced Ratio from a pair of i64 numerator/denominator.
/// Returns `null` when the reduced denominator collapses to 1 (the caller wraps
/// the numerator as a plain integer instead). Produces a SMALL ratio (no BigInt
/// alloc) — the canonical fast path (ADR-0149). MIN_I64 operands fall back to the
/// Managed path (`@abs(MIN_I64)` would overflow).
pub fn allocFromI64Pair(rt: *Runtime, num: i64, den: i64) RatioError!?Value {
    if (den == 0) return error.DivideByZero;

    const min_i64 = std.math.minInt(i64);
    if (num != min_i64 and den != min_i64) {
        const g = gcdI64(num, den); // >= 1 (den != 0)
        var rn = @divTrunc(num, g);
        var rd = @divTrunc(den, g);
        // |rn| <= |num| < 2^63 (num != MIN) so the negation cannot overflow.
        if (rd < 0) {
            rn = -rn;
            rd = -rd;
        }
        if (rd == 1) return null; // integer collapse
        return try allocSmall(rt, rn, rd);
    }

    var n_m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer n_m.deinit();
    try n_m.set(num);
    var d_m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer d_m.deinit();
    try d_m.set(den);

    return allocFromManagedPair(rt, &n_m, &d_m);
}

/// Allocate a reduced Ratio from a pair of caller-built Managed
/// numerator/denominator. The caller retains ownership of the
/// inputs (this routine clones via `cloneWithDifferentAllocator`
/// onto `rt.gc.infra` for the post-reduction storage).
///
/// Mirrors `Numbers.divide(BigInteger, BigInteger)` in JVM Clojure:
///   1. den == 0 → error.DivideByZero
///   2. gcd-reduce
///   3. sign-normalise (denom > 0 invariant)
///   4. integer-collapse on denom == 1 → null
///   5. allocate two BigInts on gc.alloc + the Ratio wrapper
pub fn allocFromManagedPair(
    rt: *Runtime,
    num: *const std.math.big.int.Managed,
    den: *const std.math.big.int.Managed,
) RatioError!?Value {
    if (den.eqlZero()) return error.DivideByZero;

    // PERF: all four reduce-scratch Managed share one stack arena, so the
    // gcd + 2× divTrunc allocate from one chunk and bulk-free on return —
    // not 4 individual GPA malloc/free per ratio result (O-038). The result
    // BigInts (numer/denom) still clone onto gc.infra below.
    var arena = std.heap.ArenaAllocator.init(rt.gc.infra);
    defer arena.deinit();
    const sa = arena.allocator();

    var gcd_m = try std.math.big.int.Managed.init(sa);
    try gcd_m.gcd(num, den);

    var r_num = try std.math.big.int.Managed.init(sa);
    var r_den = try std.math.big.int.Managed.init(sa);
    var rem_scratch = try std.math.big.int.Managed.init(sa);
    try r_num.divTrunc(&rem_scratch, num, &gcd_m);
    try r_den.divTrunc(&rem_scratch, den, &gcd_m);

    return finishReducedPair(rt, &r_num, &r_den);
}

/// Build a Ratio Value from an ALREADY-REDUCED (coprime) `num`/`den` pair —
/// sign-normalise (den > 0), collapse `den == 1` to `null` (the caller emits the
/// integer), and emit the small-i64 tier when both fit, else the big tier. This
/// is `allocFromManagedPair`'s post-gcd tail, factored so a caller that already
/// produced a reduced pair (the Knuth gcd-first ratio add, O-050) can skip the
/// redundant final gcd. Mutates `num`/`den` (negate). `den != 0` required.
pub fn allocFromReducedManagedPair(
    rt: *Runtime,
    num: *std.math.big.int.Managed,
    den: *std.math.big.int.Managed,
) RatioError!?Value {
    if (den.eqlZero()) return error.DivideByZero;
    return finishReducedPair(rt, num, den);
}

fn finishReducedPair(
    rt: *Runtime,
    r_num: *std.math.big.int.Managed,
    r_den: *std.math.big.int.Managed,
) RatioError!?Value {
    // A zero numerator is the integer 0, never a ratio (0/k is not coprime for
    // k > 1). The full-gcd `allocFromManagedPair` collapses this via gcd(0,den)=den;
    // the reduced-pair caller (Knuth add) can reach 0/k directly (acc + −acc), so
    // guard it here. `null` → the caller emits the integer 0.
    if (r_num.eqlZero()) return null;

    if (!r_den.isPositive()) {
        r_num.negate();
        r_den.negate();
    }

    if (r_den.toConst().orderAgainstScalar(1) == .eq) {
        return null;
    }

    // CANONICAL collapse (ADR-0149): if the REDUCED pair both fit i64, emit a
    // small ratio — no BigInt alloc, and (crucially) so a small `1/2` and a big
    // `1/2` never coexist, keeping the rt-free `equal`/`hash` arms correct.
    if (r_num.toConst().toInt(i64) catch null) |sn| {
        if (r_den.toConst().toInt(i64) catch null) |sd| {
            return try allocSmall(rt, sn, sd);
        }
    }

    // big tier: Ratio numerator/denominator are internal BigInts (never printed
    // standalone); `.bigint` origin is the harmless fixed choice (D-165).
    const numer_val = try big_int_mod.allocFromManaged(rt, r_num, .bigint);
    const denom_val = try big_int_mod.allocFromManaged(rt, r_den, .bigint);

    const r = try rt.gc.alloc(Ratio);
    r.* = .{
        .header = HeapHeader.init(.ratio),
        .is_small = 0,
        .a = @intFromPtr(numer_val.decodePtr(*BigInt)),
        .b = @intFromPtr(denom_val.decodePtr(*BigInt)),
    };
    return Value.encodeHeapPtr(.ratio, r);
}

/// Trace fn called by the mark phase. A SMALL ratio has inline i64s — NO GC
/// children, so it marks nothing (marking the i64 bits as a pointer would
/// corrupt the heap). A BIG ratio marks its two GC-managed BigInts (ADR-0149).
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Ratio = @ptrCast(@alignCast(header));
    if (r.is_small == 1) return;
    mark_sweep.mark(gc, &r.bigNum().header);
    mark_sweep.mark(gc, &r.bigDen().header);
}

/// Ratio has no owned non-GC resources → no finaliser. Trace alone
/// keeps numer/denom alive; sweep reclaims the Ratio itself.
pub fn registerGcHooks() void {
    tag_ops.registerTrace(.ratio, &traceGc);
}

// --- same-type comparison ---
//
// Cross-multiply approach mirroring JVM Clojure RatioOps. Both inputs
// have denom > 0 (the post-reduce invariant), so the cross-product sign
// gives the order directly.

/// Three-way compare two Ratio Values via cross-multiplication.
/// Both inputs MUST have denom > 0 (the post-reduce invariant), so
/// the sign of `(a.numer * b.denom) - (b.numer * a.denom)` is
/// the order direction directly.
pub fn compareValue(rt: *Runtime, a: Value, b: Value) !std.math.Order {
    std.debug.assert(a.tag() == .ratio and b.tag() == .ratio);
    const pa = parts(a);
    const pb = parts(b);

    // Fast path: both small → i128 cross-multiply (i64×i64 fits i128 exactly, no
    // alloc). Both denoms > 0, so the product sign gives the order directly.
    if (pa == .small and pb == .small) {
        const lhs: i128 = @as(i128, pa.small.n) * @as(i128, pb.small.d);
        const rhs: i128 = @as(i128, pb.small.n) * @as(i128, pa.small.d);
        return std.math.order(lhs, rhs);
    }

    // General (a big operand present): materialize each component as a Managed.
    const M = std.math.big.int.Managed;
    var an_m = try M.init(rt.gc.infra);
    defer an_m.deinit();
    var ad_m = try M.init(rt.gc.infra);
    defer ad_m.deinit();
    var bn_m = try M.init(rt.gc.infra);
    defer bn_m.deinit();
    var bd_m = try M.init(rt.gc.infra);
    defer bd_m.deinit();
    const an: *const M = switch (pa) {
        .small => |s| blk: {
            try an_m.set(s.n);
            break :blk &an_m;
        },
        .big => |x| x.n.m,
    };
    const ad: *const M = switch (pa) {
        .small => |s| blk: {
            try ad_m.set(s.d);
            break :blk &ad_m;
        },
        .big => |x| x.d.m,
    };
    const bn: *const M = switch (pb) {
        .small => |s| blk: {
            try bn_m.set(s.n);
            break :blk &bn_m;
        },
        .big => |x| x.n.m,
    };
    const bd: *const M = switch (pb) {
        .small => |s| blk: {
            try bd_m.set(s.d);
            break :blk &bd_m;
        },
        .big => |x| x.d.m,
    };

    var lhs = try M.init(rt.gc.infra);
    defer lhs.deinit();
    var rhs = try M.init(rt.gc.infra);
    defer rhs.deinit();
    try lhs.mul(an, bd);
    try rhs.mul(bn, ad);
    return lhs.order(rhs);
}

// --- conversion to double ---
//
// clj `Ratio.doubleValue` is `decimalValue(MathContext.DECIMAL64).doubleValue()`:
// the exact quotient rounded HALF_EVEN to 16 significant decimal digits, then
// that decimal to the nearest double. The first rounding is observable, so a
// plain f64 divide is not the same function: `-2/3` is `-0.6666666666666667`
// and `1/7` is `0.1428571428571429`, where `n / d` in f64 gives `...666` and
// `...285`. Every site that turns a Ratio into a double (`double`, float
// contagion, the mixed float comparison, `.doubleValue`, JSON) calls `toF64`.

/// The Ratio `v` as clj's `Ratio.doubleValue`. Allocation-free for a small
/// ratio; a big one borrows its numerator's allocator for the scaled divide,
/// so the only error is OutOfMemory.
pub fn toF64(v: Value) std.mem.Allocator.Error!f64 {
    return switch (parts(v)) {
        .small => |s| smallToF64(s.n, s.d),
        .big => |b| bigToF64(b.n.m, b.d.m),
    };
}

/// Decimal digit count of `x` (1 for 0).
fn digits10(x: u128) u32 {
    var n: u32 = 1;
    var y = x;
    while (y >= 10) : (n += 1) y /= 10;
    return n;
}

/// The exact positive quotient `q * 10^-scale` (`sticky` when the division
/// left a remainder) rounded HALF_EVEN to 16 significant digits, then to the
/// nearest f64. `q` carries at least 17 digits, so one is left to round on.
fn decimal64ToF64(neg: bool, q: u128, sticky: bool, scale: i64) f64 {
    const k = digits10(q) - 16;
    const p = std.math.powi(u128, 10, k) catch unreachable; // k <= 7
    var hi = q / p;
    const lo = q % p;
    const half = p / 2;
    if (lo > half or (lo == half and (sticky or hi % 2 == 1))) hi += 1;
    var buf: [64]u8 = undefined;
    const txt = std.fmt.bufPrint(&buf, "{s}{d}e{d}", .{ if (neg) "-" else "", hi, @as(i64, k) - scale }) catch unreachable;
    return std.fmt.parseFloat(f64, txt) catch unreachable;
}

/// Small tier: `|n|` has at most 19 digits and `d` at least 1, so scaling
/// `|n|` by `10^(18 + digits(d) - digits(|n|))` (never negative) gives a
/// quotient of 18 or 19 digits while the dividend stays under `10^37 < 2^128`.
fn smallToF64(n: i64, d: i64) f64 {
    const a: u128 = @abs(n);
    const b: u128 = @intCast(d);
    const s = 18 + digits10(b) - digits10(a);
    const num = a * (std.math.powi(u128, 10, s) catch unreachable); // s <= 36
    return decimal64ToF64(n < 0, num / b, num % b != 0, s);
}

/// `floor(bits * 0.30103)`: within one of the decimal digit count of any
/// integer that is `bits` bits long.
fn digitsEstimate(bits: usize) i64 {
    return @intCast(bits * 30103 / 100000);
}

/// Big tier: the same scaled divide over Managed. The scale comes from the
/// bit lengths, whose digit estimate is off by at most one either way, so the
/// `20 +` margin keeps the quotient between 18 and 23 digits (a u128).
fn bigToF64(n: *const Managed, d: *const Managed) std.mem.Allocator.Error!f64 {
    const gpa = n.allocator;
    const s: i64 = 20 + digitsEstimate(d.bitCountAbs()) - digitsEstimate(n.bitCountAbs());
    var abs_n = try n.clone();
    defer abs_n.deinit();
    abs_n.abs();
    var ten = try Managed.initSet(gpa, 10);
    defer ten.deinit();
    var p = try Managed.init(gpa);
    defer p.deinit();
    try p.pow(&ten, @intCast(@abs(s)));
    // A negative scale moves the power of ten onto the denominator.
    var scaled = try Managed.init(gpa);
    defer scaled.deinit();
    try scaled.mul(if (s >= 0) &abs_n else d, &p);
    var q = try Managed.init(gpa);
    defer q.deinit();
    var r = try Managed.init(gpa);
    defer r.deinit();
    if (s >= 0) try q.divTrunc(&r, &scaled, d) else try q.divTrunc(&r, &abs_n, &scaled);
    const qv = q.toInt(u128) catch unreachable; // at most 23 digits
    return decimal64ToF64(!n.isPositive(), qv, !r.eqlZero(), s);
}

// Ratio arithmetic (+ - * /) over ratio / mixed operands lives in the
// numeric dispatcher `promote.ratioArith`, which extracts each operand's
// numerator/denominator (this module's job is construction + reduction
// via `allocFromManagedPair`, comparison via `compareValue`, conversion to
// double via `toF64`, and GC).

// --- tests ---

const testing = std.testing;

const RatioFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() RatioFixture {
        var fix: RatioFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *RatioFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "Ratio extern struct layout: HeapHeader at offset 0, is_small discriminant, align >= 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(Ratio, "header"));
    // two-tier (ADR-0149): `a`/`b` are u64 (inline i64 for small, *BigInt for big).
    try testing.expect(@offsetOf(Ratio, "a") < @offsetOf(Ratio, "b"));
    try testing.expect(@alignOf(Ratio) >= 8);
}

test "allocFromI64Pair (1, 2) keeps numer=1 / denom=2 (no reduction needed)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 1, 2)).?;
    try testing.expect(v.tag() == .ratio);
    const p = parts(v);
    try testing.expect(p == .small);
    try testing.expectEqual(@as(i64, 1), p.small.n);
    try testing.expectEqual(@as(i64, 2), p.small.d);
}

test "allocFromI64Pair (2, 4) reduces to numer=1 / denom=2" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 2, 4)).?;
    const p = parts(v);
    try testing.expect(p == .small);
    try testing.expectEqual(@as(i64, 1), p.small.n);
    try testing.expectEqual(@as(i64, 2), p.small.d);
}

test "allocFromI64Pair (-3, 6) reduces to numer=-1 / denom=2 (sign already correct)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, -3, 6)).?;
    const p = parts(v);
    try testing.expect(p == .small);
    try testing.expectEqual(@as(i64, -1), p.small.n);
    try testing.expectEqual(@as(i64, 2), p.small.d);
}

test "allocFromI64Pair (3, -6) flips signs so denom > 0" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 3, -6)).?;
    const p = parts(v);
    try testing.expect(p == .small);
    try testing.expectEqual(@as(i64, -1), p.small.n);
    try testing.expectEqual(@as(i64, 2), p.small.d);
}

test "allocFromI64Pair (6, 3) collapses to null (integer)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = try allocFromI64Pair(&fix.rt, 6, 3);
    try testing.expect(v == null);
}

test "allocFromI64Pair (n, 0) raises DivideByZero" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    try testing.expectError(error.DivideByZero, allocFromI64Pair(&fix.rt, 5, 0));
}

test "allocFromManagedPair (2^65, 3) reduces with numerator bitcount > 64 (Linux gcd canary)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    // 2^65 — beyond i64. Use shiftLeft to dodge the Zig 0.16
    // Managed.setString Linux glibc-x86 platform bug (D-047).
    var big_num = try std.math.big.int.Managed.init(testing.allocator);
    defer big_num.deinit();
    try big_num.set(1);
    try big_num.shiftLeft(&big_num, 65);

    var three = try std.math.big.int.Managed.init(testing.allocator);
    defer three.deinit();
    try three.set(3);

    const v = (try allocFromManagedPair(&fix.rt, &big_num, &three)).?;
    // 2^65 and 3 are coprime (gcd = 1), so the reduction is a no-op. numer
    // exceeds i64 → a BIG ratio; numer bitCount > 64; denom should equal 3.
    const p = parts(v);
    try testing.expect(p == .big);
    try testing.expect(p.big.n.m.bitCountAbs() > 64);
    try testing.expectEqual(@as(i64, 3), try p.big.d.m.toInt(i64));
}

test "compareValue (1/2 vs 2/3): 1/2 < 2/3" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const a = (try allocFromI64Pair(&fix.rt, 1, 2)).?;
    const b = (try allocFromI64Pair(&fix.rt, 2, 3)).?;
    try testing.expectEqual(std.math.Order.lt, try compareValue(&fix.rt, a, b));
    try testing.expectEqual(std.math.Order.gt, try compareValue(&fix.rt, b, a));
    try testing.expectEqual(std.math.Order.eq, try compareValue(&fix.rt, a, a));
}

test "toF64 is clj Ratio.doubleValue (DECIMAL64 first, then the nearest double)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    try testing.expectEqual(@as(f64, -0.6666666666666667), try toF64((try allocFromI64Pair(&fix.rt, -2, 3)).?));
    try testing.expectEqual(@as(f64, 0.1428571428571429), try toF64((try allocFromI64Pair(&fix.rt, 1, 7)).?));
    try testing.expectEqual(@as(f64, 3.142857142857143), try toF64((try allocFromI64Pair(&fix.rt, 22, 7)).?));
    try testing.expectEqual(@as(f64, 0.5), try toF64((try allocFromI64Pair(&fix.rt, 1, 2)).?));
    // A MIN_I64 numerator stays small after reduction (|n| is exactly 2^63).
    try testing.expectEqual(@as(f64, -3.074457345618259e18), try toF64((try allocFromI64Pair(&fix.rt, std.math.minInt(i64), 3)).?));

    // Big tier: 10^23 / 3, and its reciprocal (a negative scale on the other side).
    var ten23 = try Managed.initSet(testing.allocator, 10);
    defer ten23.deinit();
    try ten23.pow(&ten23, 23);
    var three = try Managed.initSet(testing.allocator, 3);
    defer three.deinit();
    try testing.expectEqual(@as(f64, 3.333333333333333e22), try toF64((try allocFromManagedPair(&fix.rt, &ten23, &three)).?));
    try testing.expectEqual(@as(f64, 3.0e-23), try toF64((try allocFromManagedPair(&fix.rt, &three, &ten23)).?));
}

test "Runtime.deinit releases Ratio + numer/denom BigInts (no leak)" {
    var fix = RatioFixture.init();
    _ = try allocFromI64Pair(&fix.rt, 1, 2);
    _ = try allocFromI64Pair(&fix.rt, -3, 6);
    // Don't `defer fix.deinit()` — call manually so the testing
    // allocator's leak detector verifies the Ratio + both BigInts
    // (plus their *Managed limbs) all release cleanly.
    fix.deinit();
}
