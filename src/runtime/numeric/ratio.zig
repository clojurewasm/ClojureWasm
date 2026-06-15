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

/// GC-managed Ratio. Both `numer` and `denom` point at `gc.alloc`'d
/// BigInts; the GC's trace pass walks through this Ratio to keep
/// them alive. `denom` is always strictly positive after a
/// successful `allocFromManagedPair` / `allocFromI64Pair`.
pub const Ratio = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    numer: *BigInt,
    denom: *BigInt,

    comptime {
        std.debug.assert(@alignOf(Ratio) >= 8);
        std.debug.assert(@offsetOf(Ratio, "header") == 0);
        // numer / denom follow the same trailing-pad pattern as
        // BigInt so the GC walker and the reviewer see the same
        // shape across numeric heap types.
        std.debug.assert(@offsetOf(Ratio, "numer") == @offsetOf(BigInt, "m"));
    }
};

/// Errors raised by Ratio constructors. `DivideByZero` is mapped to
/// the catalog Code at the Clojure-side dispatch; the Zig API surface
/// stays narrow.
pub const RatioError = error{DivideByZero} || std.mem.Allocator.Error;

/// Allocate a reduced Ratio from a pair of i64 numerator/denominator.
/// Returns `null` when the reduced denominator collapses to 1 (the
/// caller should wrap the numerator as a plain BigInt instead).
pub fn allocFromI64Pair(rt: *Runtime, num: i64, den: i64) RatioError!?Value {
    if (den == 0) return error.DivideByZero;

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

    if (!r_den.isPositive()) {
        r_num.negate();
        r_den.negate();
    }

    if (r_den.toConst().orderAgainstScalar(1) == .eq) {
        return null;
    }

    // Ratio numerator/denominator are internal BigInts (never printed
    // standalone); `.bigint` origin is the harmless fixed choice (D-165).
    const numer_val = try big_int_mod.allocFromManaged(rt, &r_num, .bigint);
    const denom_val = try big_int_mod.allocFromManaged(rt, &r_den, .bigint);

    const r = try rt.gc.alloc(Ratio);
    r.* = .{
        .header = HeapHeader.init(.ratio),
        .numer = numer_val.decodePtr(*BigInt),
        .denom = denom_val.decodePtr(*BigInt),
    };
    return Value.encodeHeapPtr(.ratio, r);
}

/// Decode a Ratio Value into its numerator (a `*const BigInt`).
pub fn asNumer(v: Value) *const BigInt {
    std.debug.assert(v.tag() == .ratio);
    return v.decodePtr(*const Ratio).numer;
}

/// Decode a Ratio Value into its denominator (a `*const BigInt`).
pub fn asDenom(v: Value) *const BigInt {
    std.debug.assert(v.tag() == .ratio);
    return v.decodePtr(*const Ratio).denom;
}

/// Trace fn called by the mark phase. Walks `numer` and `denom` —
/// both BigInts are themselves GC-managed, so we mark their headers
/// and let the GC do the rest. Ratio has no non-GC owned resources.
pub fn traceGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const r: *Ratio = @ptrCast(@alignCast(header));
    mark_sweep.mark(gc, &r.numer.header);
    mark_sweep.mark(gc, &r.denom.header);
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
    const ar = a.decodePtr(*const Ratio);
    const br = b.decodePtr(*const Ratio);

    var lhs = try std.math.big.int.Managed.init(rt.gc.infra);
    defer lhs.deinit();
    var rhs = try std.math.big.int.Managed.init(rt.gc.infra);
    defer rhs.deinit();
    try lhs.mul(ar.numer.m, br.denom.m);
    try rhs.mul(br.numer.m, ar.denom.m);
    return lhs.order(rhs);
}

// Ratio arithmetic (+ - * /) over ratio / mixed operands lives in the
// numeric dispatcher `promote.ratioArith`, which extracts each operand's
// numerator/denominator (this module's job is construction + reduction
// via `allocFromManagedPair`, comparison via `compareValue`, and GC).

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

test "Ratio extern struct layout: HeapHeader at offset 0, numer matches BigInt layout, align >= 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(Ratio, "header"));
    try testing.expectEqual(@offsetOf(BigInt, "m"), @offsetOf(Ratio, "numer"));
    try testing.expect(@alignOf(Ratio) >= 8);
}

test "allocFromI64Pair (1, 2) keeps numer=1 / denom=2 (no reduction needed)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 1, 2)).?;
    try testing.expect(v.tag() == .ratio);
    try testing.expectEqual(@as(i64, 1), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asNumer(v))).toInt(i64));
    try testing.expectEqual(@as(i64, 2), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asDenom(v))).toInt(i64));
}

test "allocFromI64Pair (2, 4) reduces to numer=1 / denom=2" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 2, 4)).?;
    try testing.expectEqual(@as(i64, 1), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asNumer(v))).toInt(i64));
    try testing.expectEqual(@as(i64, 2), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asDenom(v))).toInt(i64));
}

test "allocFromI64Pair (-3, 6) reduces to numer=-1 / denom=2 (sign already correct)" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, -3, 6)).?;
    try testing.expectEqual(@as(i64, -1), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asNumer(v))).toInt(i64));
    try testing.expectEqual(@as(i64, 2), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asDenom(v))).toInt(i64));
}

test "allocFromI64Pair (3, -6) flips signs so denom > 0" {
    var fix = RatioFixture.init();
    defer fix.deinit();

    const v = (try allocFromI64Pair(&fix.rt, 3, -6)).?;
    try testing.expectEqual(@as(i64, -1), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asNumer(v))).toInt(i64));
    try testing.expectEqual(@as(i64, 2), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asDenom(v))).toInt(i64));
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
    // 2^65 and 3 are coprime (gcd = 1), so the reduction is a no-op.
    // numer should still have bitCount > 64; denom should equal 3.
    try testing.expect(big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asNumer(v))).bitCountAbs() > 64);
    try testing.expectEqual(@as(i64, 3), try big_int_mod.asManaged(Value.encodeHeapPtr(.big_int, asDenom(v))).toInt(i64));
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

test "Runtime.deinit releases Ratio + numer/denom BigInts (no leak)" {
    var fix = RatioFixture.init();
    _ = try allocFromI64Pair(&fix.rt, 1, 2);
    _ = try allocFromI64Pair(&fix.rt, -3, 6);
    // Don't `defer fix.deinit()` — call manually so the testing
    // allocator's leak detector verifies the Ratio + both BigInts
    // (plus their *Managed limbs) all release cleanly.
    fix.deinit();
}
