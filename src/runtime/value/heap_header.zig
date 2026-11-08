// SPDX-License-Identifier: EPL-2.0
//! 8-byte header prefixed to every heap-allocated cw v1 Value object.
//!
//! Per ADR-0009: low 2 bits of `gc_and_lock` are the heap-only lock
//! state (reserved; `monitor-enter` / `monitor-exit` / `locking` wire
//! to them when concurrency lands in Phase B — single-threaded today,
//! so they stay zero). High 30 bits are the GC mark / age: the
//! mark-sweep collector (ADR-0028) uses bit 0 as the live mark; bits
//! 1..29 are spare width for a future generational counter and stay
//! zero today.

const std = @import("std");
const testing = std.testing;

const heap_tag = @import("heap_tag.zig");
const HeapTag = heap_tag.HeapTag;

/// 8-byte header prefixed to every heap-allocated object. Used by GC
/// for mark/sweep and by the runtime for fine-grained type dispatch.
pub const HeapHeader = extern struct {
    /// HeapTag discriminant (0–63 per ADR-0027 §2 + F-004 g2 layout).
    /// align(8): every heap object is 8-aligned (NaN-box invariant).
    tag: u8 align(8),
    /// Per-object GC and lifecycle flags.
    flags: Flags,
    /// Padding so `gc_and_lock` lands on its natural 4-byte boundary.
    _pad: [2]u8 = .{ 0, 0 },
    /// ROADMAP §9.6 / 4.19 + ADR-0009: low 2 bits are the heap-only
    /// lock state, high 30 bits are the GC mark / age. The mark-sweep
    /// collector reads/writes the mark bit (mark/clear in
    /// `mark_sweep.zig`). The lock_state bits stay reserved until
    /// Phase B wires `monitor-enter` / `monitor-exit` / `locking` and
    /// `dosync` to them.
    gc_and_lock: GcAndLock = .{},

    pub const Flags = packed struct(u8) {
        /// Arena freeze flag — prevents mutation after snapshot.
        frozen: bool = false,
        _pad: u7 = 0,
    };

    pub const GcAndLock = packed struct(u32) {
        /// 0 = unlocked, 1 = light-locked, 2 = heavyweight, 3 = reserved.
        lock_state: u2 = 0,
        /// Phase 5 mark-sweep collector reads/writes this. Wider than
        /// strictly necessary for a single bit so a generational
        /// counter can fit later without a struct migration.
        gc_mark: u30 = 0,
    };

    pub fn init(heap_tag_v: HeapTag) HeapHeader {
        return .{ .tag = @intFromEnum(heap_tag_v), .flags = .{} };
    }
};

// --- tests ---

test "HeapHeader layout and flags" {
    var hdr = HeapHeader.init(.string);
    try testing.expectEqual(@as(u8, 0), hdr.tag);
    try testing.expect(!hdr.flags.frozen);

    hdr.flags.frozen = true;
    try testing.expect(hdr.flags.frozen);

    // GC mark bit migrated to gc_and_lock.gc_mark per ADR-0009
    // amendment 2 + 5.3.b.2 implementation; verify gc_mark bit 0
    // sets independently of flags.
    hdr.gc_and_lock.gc_mark = 1;
    try testing.expectEqual(@as(u30, 1), hdr.gc_and_lock.gc_mark);
    try testing.expect(hdr.flags.frozen); // flags unchanged
}

test "HeapHeader is 8 bytes (tag + flags + pad + gc_and_lock)" {
    // Phase 4 task 4.19 + ADR-0009 extend the header from 2 → 8 bytes
    // to reserve the gc_and_lock u32 slot (with natural 4-byte
    // alignment after tag/flags + 2 bytes of padding).
    try testing.expectEqual(@as(usize, 8), @sizeOf(HeapHeader));
}

test "HeapHeader.GcAndLock packs lock_state + gc_mark into 4 bytes" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(HeapHeader.GcAndLock));
    var gl: HeapHeader.GcAndLock = .{};
    try testing.expectEqual(@as(u2, 0), gl.lock_state);
    try testing.expectEqual(@as(u30, 0), gl.gc_mark);

    gl.lock_state = 2;
    gl.gc_mark = 0x3F_FF_FF_FF;
    try testing.expectEqual(@as(u2, 2), gl.lock_state);
    try testing.expectEqual(@as(u30, 0x3F_FF_FF_FF), gl.gc_mark);
}

test "HeapHeader.init zero-initialises gc_and_lock" {
    const hdr = HeapHeader.init(.string);
    try testing.expectEqual(@as(u2, 0), hdr.gc_and_lock.lock_state);
    try testing.expectEqual(@as(u30, 0), hdr.gc_and_lock.gc_mark);
}
