// SPDX-License-Identifier: EPL-2.0
//! Free-pool recycling for cw v1 mark-sweep GC per ADR-0028 §3.
//!
//! **Phase 5 row 5.3.a skeleton.** The struct shapes land here:
//!   - `FreeNode { next: ?*FreeNode }` — intrusive linked-list node
//!     overlaid in the freed object's payload **at offset 8** (per
//!     ADR-0028 §3 DIVERGENCE from cw v0 which overlaid at offset 0
//!     and clobbered the header).
//!   - `FreePoolKey { size, alignment }` — hash key for the per-
//!     (size, alignment) pool head map.
//!   - `FreePoolMap` — `std.AutoHashMapUnmanaged(FreePoolKey, ?*FreeNode)`
//!     wrapper with `empty` / `deinit` / `push` / `pop` methods.
//!
//! Behaviour-bearing methods are stubs at 5.3.a; 5.3.c wires the
//! intrusive overlay + push/pop fast-path + the per-size-class
//! optimisation (Devil's-advocate Wildcard Alt 3 candidate — quantise
//! sizes to N power-of-2 classes and replace the HashMap with a flat
//! `[N]?*FreeNode` array; 5.3 owner picks per measured size-class
//! distribution per ADR-0028 §6 F-003 deferral).
//!
//! Minimum allocation size: **16 bytes** (per ADR-0028 §3) so the
//! freed payload can host `@sizeOf(FreeNode) = 8` bytes after the
//! 8-byte HeapHeader. Allocations under 16 bytes round up.

const std = @import("std");
const testing = std.testing;

/// Intrusive free-list node, overlaid in the freed object's payload
/// at offset 8 (after the 8-byte HeapHeader). The freed block's
/// payload must be ≥ `@sizeOf(FreeNode) = 8` bytes — combined with
/// the 8-byte header this gives the 16-byte minimum allocation that
/// ADR-0028 §3 enforces.
pub const FreeNode = struct {
    next: ?*FreeNode = null,
};

/// Per-(size, alignment) free pool key. Alignment is always 8 per
/// ADR-0027 §1 `align(8)` invariant, so an optimised future shape
/// can collapse to a size-only key + per-size-class array (the
/// Devil's-advocate Wildcard Alt 3 candidate captured in ADR-0028 §3
/// + §6's F-003 deferral).
pub const FreePoolKey = struct {
    size: usize,
    alignment: u8,

    pub fn eql(self: FreePoolKey, other: FreePoolKey) bool {
        return self.size == other.size and self.alignment == other.alignment;
    }
};

/// Per-(size, alignment) free pool head map. **Phase 5.3.a skeleton.**
/// 5.3.c lands the `push(self, infra, key, node)` / `pop(self, key)
/// ?*FreeNode` fast-path + the deinit (drains every pool, returns
/// node memory to `infra` via `raw_free`).
pub const FreePoolMap = struct {
    /// HashMap from key to pool head. `null` head = pool exists with
    /// no free nodes; absent key = pool not yet observed at any size.
    /// 5.3.c picks between the HashMap shape (declared here) vs the
    /// flat-array Wildcard Alt 3 shape per measured distribution.
    map: std.AutoHashMapUnmanaged(FreePoolKey, ?*FreeNode) = .empty,

    pub const empty: FreePoolMap = .{};

    pub fn deinit(self: *FreePoolMap, infra: std.mem.Allocator) void {
        // 5.3.c walks every pool head and `infra.rawFree`s each freed
        // node's backing memory. At 5.3.a skeleton the map is always
        // empty so we just drop the HashMap state.
        self.map.deinit(infra);
    }
};

// --- tests ---

test "FreeNode is at most 16 bytes (intrusive overlay budget)" {
    // @sizeOf(FreeNode) ≤ 8 ensures it fits in the payload of the
    // 16-byte minimum allocation after the 8-byte HeapHeader. On 64-
    // bit targets this is exactly 8 bytes (single `?*FreeNode`).
    try testing.expect(@sizeOf(FreeNode) <= 8);
}

test "FreePoolKey eql" {
    const k1 = FreePoolKey{ .size = 32, .alignment = 8 };
    const k2 = FreePoolKey{ .size = 32, .alignment = 8 };
    const k3 = FreePoolKey{ .size = 64, .alignment = 8 };

    try testing.expect(k1.eql(k2));
    try testing.expect(!k1.eql(k3));
}

test "FreePoolMap empty init + deinit" {
    var pool: FreePoolMap = .empty;
    defer pool.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), pool.map.count());
}
