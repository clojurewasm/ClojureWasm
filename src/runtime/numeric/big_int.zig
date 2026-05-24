// SPDX-License-Identifier: EPL-2.0
//! Arbitrary-precision integer heap struct per F-005 + ADR-0012
//! amendment 1 + ADR-0027 §2 Group D slot 0.
//!
//! ## 5.9.a migration (resolves 5.3.d.9 deferral)
//!
//! BigInt is now an `extern struct` with HeapHeader at offset 0 +
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
//! ADR-0027 §2. Phase 5 row 5.2.b rotated the slot from the g1
//! placement at 29 (released `wasm_module` slot per ADR-0006 a1 +
//! ADR-0012 a1) to the canonical Group D numeric block.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const HeapHeader = value_mod.HeapHeader;
const Value = value_mod.Value;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");

/// Heap-allocated arbitrary-precision integer. The wrapper is GC-
/// managed; the `*Managed` it points at lives on `gc.infra` (process-
/// lifetime GPA per F-006). The finaliser releases both.
pub const BigInt = extern struct {
    header: HeapHeader,
    _pad: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    /// Pointer to a `Managed` allocated on `gc.infra`. The Managed
    /// owns its limb slice via its embedded allocator (also gc.infra).
    /// `finaliseGc` chains `m.deinit()` + `infra.destroy(m)`.
    m: *std.math.big.int.Managed,

    comptime {
        std.debug.assert(@alignOf(BigInt) >= 8);
        std.debug.assert(@offsetOf(BigInt, "header") == 0);
    }
};

/// Allocate a BigInt holding the i64 `v`. The Managed is constructed
/// on `rt.gc.infra` (GPA) per F-006 §2; the BigInt wrapper lives on
/// `rt.gc.alloc` (GC heap). Finaliser releases both at sweep time.
pub fn allocFromI64(rt: *Runtime, v: i64) !Value {
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.set(v);

    const bi = try rt.gc.alloc(BigInt);
    bi.* = .{ .header = HeapHeader.init(.big_int), .m = m_ptr };
    return Value.encodeHeapPtr(.big_int, bi);
}

/// Allocate a BigInt from a base-10 string. Useful for literals
/// that overflow i64 at the analyser. Fails with the underlying
/// parse-error union from `Managed.setString`.
pub fn allocFromString(rt: *Runtime, base: u8, s: []const u8) !Value {
    const m_ptr = try rt.gc.infra.create(std.math.big.int.Managed);
    errdefer rt.gc.infra.destroy(m_ptr);
    m_ptr.* = try std.math.big.int.Managed.init(rt.gc.infra);
    errdefer m_ptr.deinit();
    try m_ptr.setString(base, s);

    const bi = try rt.gc.alloc(BigInt);
    bi.* = .{ .header = HeapHeader.init(.big_int), .m = m_ptr };
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
pub fn registerGcHooks() void {
    tag_ops.registerFinaliser(.big_int, &finaliseGc);
}

/// Decode a BigInt Value into its *Managed for read-only access.
pub fn asManaged(v: Value) *const std.math.big.int.Managed {
    std.debug.assert(v.tag() == .big_int);
    return v.decodePtr(*const BigInt).m;
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

    const v = try allocFromI64(&fix.rt, 12345);
    try testing.expect(v.tag() == .big_int);
    const m = asManaged(v);
    try testing.expectEqual(@as(i64, 12345), try m.toInt(i64));
}

test "allocFromI64 + asManaged round-trip on negative value" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    const v = try allocFromI64(&fix.rt, -987654321);
    const m = asManaged(v);
    try testing.expectEqual(@as(i64, -987654321), try m.toInt(i64));
}

test "allocFromString holds values beyond i64 range" {
    var fix = RuntimeFixture.init();
    defer fix.deinit();

    // 2^65 — beyond i64.
    const v = try allocFromString(&fix.rt, 10, "36893488147419103232");
    const m = asManaged(v);
    try testing.expect(m.bitCountAbs() > 64);
    // Verify the string round-trip (canonical representation).
    const s = try m.toString(testing.allocator, 10, .lower);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("36893488147419103232", s);
}

test "Runtime.deinit releases BigInt + Managed limbs (no leak)" {
    var fix = RuntimeFixture.init();
    _ = try allocFromI64(&fix.rt, 42);
    _ = try allocFromString(&fix.rt, 10, "99999999999999999999");
    // Don't `defer fix.deinit()` — call manually so the testing
    // allocator's leak detector verifies the finaliser ran.
    fix.deinit();
}
