// SPDX-License-Identifier: EPL-2.0
//! Arbitrary-precision integer heap struct per F-005 + ADR-0012
//! amendment 1 + ADR-0027 §2 Group D slot 0.
//!
//! BigInt is an `extern struct` with HeapHeader at offset 0 +
//! a `*Managed` wrapper field. `std.math.big.int.Managed` cannot be
//! embedded directly in an extern struct (its `limbs: []Limb` slice
//! and `allocator: std.mem.Allocator` fields are not C-ABI-extern),
//! so we hold a pointer to a `Managed` allocated separately on the
//! infra_alloc (per F-006 §2 layer 1 — limbs live on GPA, not on
//! the GC heap, per the Block B reconciliation in ADR-0028 §2).
//!
//! The per-tag finaliser (`finaliseGc`, registered into
//! `tag_ops.tag_finaliser_table[.big_int]` at `registerGcHooks`)
//! deinitialises the Managed (releases limbs back to infra_alloc)
//! and destroys the Managed allocation before sweep rawFrees the
//! BigInt wrapper.
//!
//! HeapTag slot 48 (Group D position 0, `big_int`) per F-004 +
//! ADR-0027 §2.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const HeapHeader = value_mod.HeapHeader;
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const hash = @import("../hash.zig");

/// Heap-allocated arbitrary-precision integer. The wrapper is GC-
/// managed; the `*Managed` it points at lives on `gc.infra` (process-
/// lifetime GPA per F-006). The finaliser releases both.
/// Whether a heap integer represents a primitive Long (overflowed cljw's
/// i48 inline range but stays ≤ i64) or a genuine arbitrary-precision
/// BigInt (D-165 / ADR-0080 — B2). INTENT-based, set by the producing call,
/// NEVER inferred from magnitude: `(parse-long "999999999999999")` →
/// `.long`, `(bigint 5)` / `5N` → `.bigint`. Gates print (`N` suffix),
/// `(class)` / `instance?` (Long vs BigInt), and the FIXED-PRECISION
/// predicates `int?` / `pos-int?` / `neg-int?` / `nat-int?` (a `.long`-origin
/// heap Long is `int?`, a `.bigint` is not); `=` / hash are value-based
/// (D-205) and ignore it.
pub const IntOrigin = enum(u8) { long, bigint };

pub const BigInt = extern struct {
    header: HeapHeader,
    /// D-165 / ADR-0080: heap-Long vs genuine-BigInt discriminator. One
    /// byte carved from the trailing pad so `m`'s offset is unchanged (the
    /// `@offsetOf(BigInt, "m")` asserts in ratio.zig / big_decimal.zig stay
    /// green).
    origin: IntOrigin = .bigint,
    _pad: [5]u8 = .{ 0, 0, 0, 0, 0 },
    /// Pointer to a `Managed` allocated on `gc.infra`. The Managed
    /// owns its limb slice via its embedded allocator (also gc.infra).
    /// `finaliseGc` chains `m.deinit()` + `infra.destroy(m)`.
    m: *std.math.big.int.Managed,

    comptime {
        std.debug.assert(@alignOf(BigInt) >= 8);
        std.debug.assert(@offsetOf(BigInt, "header") == 0);
    }
};

/// The heap integer's origin (D-165). Caller must know `v` is `.big_int`.
pub fn originOf(v: Value) IntOrigin {
    return v.decodePtr(*const BigInt).origin;
}

/// The heap integer's value as an i64, or `error.TargetTooSmall` /
/// `error.NegativeIntoUnsigned` when it does not fit. Caller must know `v` is
/// `.big_int`. Used where a magnitude only matters up to i64 (e.g. a `take`
/// count larger than any realizable sequence is treated as unbounded).
pub fn toI64(v: Value) !i64 {
    return v.decodePtr(*const BigInt).m.toInt(i64);
}

/// Parse a base-10 digit string `[-+]?ddd` into a Managed on `rt.gc.infra`,
/// WITHOUT `std`'s `setString` — which has a Linux-glibc-x86 off-by-one past
/// 2^64 (D-047). Builds the value as `acc = acc·10 + digit`, exact on every
/// platform. `error.InvalidCharacter` on a non-digit or empty mantissa; the
/// caller owns the returned Managed.
pub fn parseBase10(rt: *Runtime, s: []const u8) !std.math.big.int.Managed {
    var t = s;
    var neg = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        neg = t[0] == '-';
        t = t[1..];
    }
    if (t.len == 0) return error.InvalidCharacter;
    var acc = try std.math.big.int.Managed.initSet(rt.gc.infra, 0);
    errdefer acc.deinit();
    var ten = try std.math.big.int.Managed.initSet(rt.gc.infra, 10);
    defer ten.deinit();
    var scratch = try std.math.big.int.Managed.init(rt.gc.infra);
    defer scratch.deinit();
    for (t) |c| {
        if (c < '0' or c > '9') return error.InvalidCharacter;
        try scratch.mul(&acc, &ten);
        try acc.addScalar(&scratch, c - '0');
    }
    if (neg) acc.negate();
    return acc;
}

/// Allocate a BigInt holding the i64 `v`. The Managed is constructed
/// on `rt.gc.infra` (GPA) per F-006 §2; the BigInt wrapper lives on
/// `rt.gc.alloc` (GC heap). Finaliser releases both at sweep time.
pub fn allocFromI64(rt: *Runtime, v: i64, origin: IntOrigin) !Value {
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.set(v);
    return wrapManaged(rt, m_ptr, origin);
}

/// Allocate a BigInt as a copy of an existing Managed. The source's
/// limbs are deep-copied through `Managed.clone` so the caller's
/// Managed can be deinit'd independently. Useful when arithmetic
/// produces a Managed result that needs to land on the GC heap.
///
/// **Note**: do NOT use `Managed.setString` for base-10 input — it has a
/// Linux glibc-x86 off-by-one past 2^64 in Zig 0.16 (D-047). Parse base-10
/// digit strings via `parseBase10` above (platform-independent mul/add); use
/// `set` + bit-shift for powers of two.
pub fn allocFromManaged(rt: *Runtime, src: *const std.math.big.int.Managed, origin: IntOrigin) !Value {
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try src.cloneWithDifferentAllocator(rt.gc.infra);
    errdefer m_ptr.deinit();
    return wrapManaged(rt, m_ptr, origin);
}

/// Wrap an already-computed, `gc.infra`-owned `*Managed` as a GC BigInt Value
/// WITHOUT cloning. The arith fast path computes its result DIRECTLY into a
/// fresh `m_ptr` (no temp Managed + `allocFromManaged` deep-copy), so this only
/// attaches the GC wrapper. The caller owns `m_ptr`'s cleanup (its two
/// errdefers: `destroy` the Managed alloc + `deinit` its limbs) until this
/// returns; on `gc.alloc` failure those errdefers free it (this fn never
/// deinits, so no double-free). PERF: O-047 — the no-clone result path shared
/// by the arith primitives here AND `promote.zig`'s `wrapArithCell`.
pub fn wrapManaged(rt: *Runtime, m_ptr: *std.math.big.int.Managed, origin: IntOrigin) !Value {
    const bi = try rt.gc.alloc(BigInt);
    bi.* = .{ .header = HeapHeader.init(.big_int), .origin = origin, .m = m_ptr };
    // CLJW-GC-HEAP-RETURN: the limbs live on infra, invisible to the trigger.
    rt.gc.noteOwnedAlloc(ownedBytes(&bi.header));
    return Value.encodeHeapPtr(.big_int, bi);
}

/// Per-tag finaliser called by sweep before unlink + rawFree (or by
/// GcHeap.deinit on shutdown). Releases the Managed's limb storage
/// + destroys the Managed allocation itself.
pub fn finaliseGc(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const bi: *BigInt = @ptrCast(@alignCast(header));
    bi.m.deinit();
    gc.infra.destroy(bi.m);
}

/// BigInt has no Value fields → no trace fn needed (the GC walks
/// the live list, sees BigInt's tag, and skips the per-tag trace
/// table lookup when no entry is registered).
/// D-573: the Managed header + its limb storage, which is what finaliseGc
/// frees. `limbs.len` is the allocated capacity (std.math.big Managed).
fn ownedBytes(header: *HeapHeader) usize {
    const bi: *BigInt = @ptrCast(@alignCast(header));
    return @sizeOf(std.math.big.int.Managed) + bi.m.limbs.len * @sizeOf(std.math.big.Limb);
}

pub fn registerGcHooks() void {
    tag_ops.registerFinaliser(.big_int, &finaliseGc);
    tag_ops.registerOwnedBytes(.big_int, &ownedBytes);
}

/// Decode a BigInt Value into its *Managed for read-only access.
pub fn asManaged(v: Value) *const std.math.big.int.Managed {
    std.debug.assert(v.tag() == .big_int);
    return v.decodePtr(*const BigInt).m;
}

// --- same-type arithmetic ---
//
// Cross-type dispatch (Long ↔ BigInt ↔ Ratio ↔ BigDecimal) lives in
// `runtime/numeric/promote.zig`. The functions below are the per-type
// building blocks the dispatcher composes.

/// Three-way compare two BigInt Values (a vs b). Both Values MUST
/// have `tag() == .big_int`.
pub fn compareManaged(a: *const std.math.big.int.Managed, b: *const std.math.big.int.Managed) std.math.Order {
    return a.order(b.*);
}

/// Value-based hash of a BigInt Managed (D-205). When the value fits an
/// i64 it hashes via `hashLong` so an integer-valued BigInt hashes EQUAL to
/// a Long of the same value — clj's cross-representation key parity
/// (`(hash 1N)` == `(hash 1)`, so `(get {1 :v} 1N)` → `:v`). Out of i64
/// range it hashes the limb bytes + sign deterministically. Replaces the
/// pre-D-205 pointer-bits hash (which was non-deterministic and broke
/// BigInt map keys / set elements). rt-free — usable from `keyEqValue`.
pub fn managedHash(m: *const std.math.big.int.Managed) u32 {
    const c = m.toConst();
    if (c.toInt(i64)) |i| {
        return hash.hashLong(i);
    } else |_| {
        var h = hash.hashString(std.mem.sliceAsBytes(c.limbs));
        if (!c.positive) h = h *% 31 +% 7;
        return h;
    }
}

/// Allocate `a + b` as a fresh BigInt on the GC heap. Limbs of the
/// result live on `rt.gc.infra`; the wrapper lives on `rt.gc.alloc`.
pub fn allocAddManaged(
    rt: *Runtime,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    origin: IntOrigin,
) !Value {
    // PERF: O-047 — compute directly into the final GC cell (no temp Managed +
    // allocFromManaged deep-copy). [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.add(a, b);
    return wrapManaged(rt, m_ptr, origin);
}

/// Allocate `a - b`.
pub fn allocSubManaged(
    rt: *Runtime,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    origin: IntOrigin,
) !Value {
    // PERF: O-047 — direct-into-cell, no clone. [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.sub(a, b);
    return wrapManaged(rt, m_ptr, origin);
}

/// Allocate `a * b`.
pub fn allocMulManaged(
    rt: *Runtime,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    origin: IntOrigin,
) !Value {
    // PERF: O-047 — direct-into-cell, no clone (the bigint_factorial hot path:
    // ~100k multiplies, each previously alloc'd a temp + memcpy'd the limbs).
    // [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.mul(a, b);
    return wrapManaged(rt, m_ptr, origin);
}

/// Floor-divide `a / b` (integer quotient toward -∞). Raises
/// `error.DivideByZero` on `b == 0`. Cross-type promotion of
/// non-exact integer division to Ratio is the `promote.zig`
/// dispatcher's responsibility; this entry returns the floor quotient
/// and discards the remainder.
pub fn allocDivFloorManaged(
    rt: *Runtime,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    origin: IntOrigin,
) !Value {
    if (b.eqlZero()) return error.DivideByZero;
    // PERF: O-047 — quotient computed directly into the final GC cell; the
    // remainder is a throwaway temp. [refs: O-047, D-450]
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    var rem = try std.math.big.int.Managed.init(rt.gc.infra);
    defer rem.deinit();
    try m_ptr.divFloor(&rem, a, b);
    return wrapManaged(rt, m_ptr, origin);
}

/// Truncate-divide `a / b` (integer quotient toward zero — JVM `BigInteger.divide`,
/// distinct from `allocDivFloorManaged`: `-7/2` = `-3` here, `-4` there). Raises
/// `error.DivideByZero` on `b == 0`.
pub fn allocDivTruncManaged(
    rt: *Runtime,
    a: *const std.math.big.int.Managed,
    b: *const std.math.big.int.Managed,
    origin: IntOrigin,
) !Value {
    if (b.eqlZero()) return error.DivideByZero;
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    var rem = try std.math.big.int.Managed.init(rt.gc.infra);
    defer rem.deinit();
    try m_ptr.divTrunc(&rem, a, b);
    return wrapManaged(rt, m_ptr, origin);
}

// --- tests ---

const testing = std.testing;

const RuntimeFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init() RuntimeFixture {
        var fix: RuntimeFixture = .{
            .threaded = std.Io.Threaded.init(testing.allocator, .{}),
            .rt = undefined,
        };
        fix.rt = Runtime.init(fix.threaded.io(), testing.allocator);
        return fix;
    }
    fn deinit(self: *RuntimeFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

test "BigInt extern struct layout: HeapHeader at offset 0, align ≥ 8" {
    try testing.expectEqual(@as(usize, 0), @offsetOf(BigInt, "header"));
    try testing.expect(@alignOf(BigInt) >= 8);
}

test "allocFromI64 + asManaged round-trip on small value" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try allocFromI64(&fix.rt, 12345, .long);
    try testing.expect(v.tag() == .big_int);
    const m = asManaged(v);
    try testing.expectEqual(@as(i64, 12345), try m.toInt(i64));
}

test "allocFromI64 + asManaged round-trip on negative value" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try allocFromI64(&fix.rt, -987654321, .long);
    const m = asManaged(v);
    try testing.expectEqual(@as(i64, -987654321), try m.toInt(i64));
}

test "allocFromManaged holds values beyond i64 range (2^65 via shiftLeft)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // 2^65 — beyond i64. Construct via `set(1)` + `shiftLeft(65)`
    // (avoids the Zig-0.16 Managed.setString Linux glibc-x86
    // off-by-one; see D-047 + allocFromManaged docstring).
    var src = try std.math.big.int.Managed.init(testing.allocator);
    defer src.deinit();
    try src.set(1);
    try src.shiftLeft(&src, 65);

    const v = try allocFromManaged(&fix.rt, &src, .long);
    const m = asManaged(v);
    try testing.expect(m.bitCountAbs() > 64);
    try testing.expect(m.eql(src));
}

test "parseBase10 is exact past 2^64 (D-047 canary: 2^65 string)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // 2^65 = 36893488147419103232 — the exact value std setString miscomputes
    // on Linux glibc-x86 (D-047). parseBase10 builds it via mul/add, so it is
    // correct on every platform.
    var parsed = try parseBase10(&fix.rt, "36893488147419103232");
    defer parsed.deinit();
    var expected = try std.math.big.int.Managed.init(testing.allocator);
    defer expected.deinit();
    try expected.set(1);
    try expected.shiftLeft(&expected, 65);
    try testing.expect(parsed.eql(expected));

    var neg = try parseBase10(&fix.rt, "-36893488147419103232");
    defer neg.deinit();
    try testing.expect(!neg.isPositive());
    try testing.expectError(error.InvalidCharacter, parseBase10(&fix.rt, "12x3"));
    try testing.expectError(error.InvalidCharacter, parseBase10(&fix.rt, ""));
}

test "compareManaged orders (3 < 5 == 5)" {
    var a = try std.math.big.int.Managed.init(testing.allocator);
    defer a.deinit();
    try a.set(3);
    var b = try std.math.big.int.Managed.init(testing.allocator);
    defer b.deinit();
    try b.set(5);

    try testing.expectEqual(std.math.Order.lt, compareManaged(&a, &b));
    try testing.expectEqual(std.math.Order.gt, compareManaged(&b, &a));
    try testing.expectEqual(std.math.Order.eq, compareManaged(&a, &a));
}

test "allocAddManaged / SubManaged / MulManaged round-trip" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var a = try std.math.big.int.Managed.init(testing.allocator);
    defer a.deinit();
    try a.set(7);
    var b = try std.math.big.int.Managed.init(testing.allocator);
    defer b.deinit();
    try b.set(5);

    const sum_v = try allocAddManaged(&fix.rt, &a, &b, .long);
    try testing.expectEqual(@as(i64, 12), try asManaged(sum_v).toInt(i64));

    const diff_v = try allocSubManaged(&fix.rt, &a, &b, .long);
    try testing.expectEqual(@as(i64, 2), try asManaged(diff_v).toInt(i64));

    const prod_v = try allocMulManaged(&fix.rt, &a, &b, .long);
    try testing.expectEqual(@as(i64, 35), try asManaged(prod_v).toInt(i64));
}

test "allocDivFloorManaged raises DivideByZero on b=0" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var a = try std.math.big.int.Managed.init(testing.allocator);
    defer a.deinit();
    try a.set(7);
    var z = try std.math.big.int.Managed.init(testing.allocator);
    defer z.deinit();
    try z.set(0);

    try testing.expectError(error.DivideByZero, allocDivFloorManaged(&fix.rt, &a, &z, .long));
}

test "allocDivFloorManaged returns floor quotient (7 / 2 = 3)" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    var a = try std.math.big.int.Managed.init(testing.allocator);
    defer a.deinit();
    try a.set(7);
    var b = try std.math.big.int.Managed.init(testing.allocator);
    defer b.deinit();
    try b.set(2);

    const q = try allocDivFloorManaged(&fix.rt, &a, &b, .long);
    try testing.expectEqual(@as(i64, 3), try asManaged(q).toInt(i64));
}

test "Runtime.deinit releases BigInt + Managed limbs (no leak)" {
    var fix = RuntimeFixture.init();
    _ = try allocFromI64(&fix.rt, 42, .long);
    _ = try allocFromI64(&fix.rt, std.math.maxInt(i64), .long);
    // Don't `defer fix.deinit()` — call manually so the testing
    // allocator's leak detector verifies the finaliser ran.
    fix.deinit();
}
