// SPDX-License-Identifier: EPL-2.0
//! Size-classed page heap: the backing store for small GC cells.
//!
//! Replaces the per-exact-size free pools (ADR-0028 §3, `free_pool.zig`),
//! which had two defects that made a long-lived cljw process only grow
//! (CLJW-GC-HEAP-RETURN):
//!
//!   1. **No return.** A swept cell was pushed onto a pool and kept for the
//!      life of the process. The pool never handed a byte back to `infra`, so
//!      the OS never got it back either: RSS was a high-water mark.
//!   2. **No sharing.** A pool was keyed by the exact (size, alignment), so a
//!      freed 264-byte vector node could only ever become another 264-byte
//!      vector node. Every size a program had ever used held its own peak.
//!
//! Shape: memory comes from the OS in `page_bytes` (64 KiB) pages, aligned to
//! their size, so the page owning any cell is `addr & ~(page_bytes - 1)` with no
//! lookup. Each page serves one size class and carries its own header (free
//! list, bump offset, live count) at offset 0. A cell freed by sweep goes onto
//! its page's free list, so the moment a page's live count reaches zero the
//! whole page is reclaimable, which a global per-size free list can never tell.
//!
//! After every sweep `release` rebuilds the per-class available lists and
//! unmaps empty pages beyond a retention budget (the hysteresis: see
//! `GcHeap.retainBytesAfterCollect`). Cells larger than `max_small_bytes`, or
//! over-aligned, are not served here; `GcHeap` sends them to `infra`, whose
//! large-block path (mmap on every allocator cljw links) already returns them.
//!
//! The freed-slot link is overlaid at offset 8, after the stale HeapHeader,
//! exactly as the old pools did (ADR-0028 §3 divergence from cw v0): offset 0
//! keeps the header bytes so a stray read of a dead cell sees a header, not a
//! pointer. Hence `min_alloc_bytes = 16`.
//!
//! Not thread-safe on its own: every call happens under `GcHeap.gc_mutex`
//! (alloc) or inside the stop-the-world collect (sweep, release).

const std = @import("std");
const testing = std.testing;

/// Page size and alignment. 64 KiB: large enough that the 64-byte header and
/// the tail waste stay small for the 4 KiB class (15 slots, 6 % waste), small
/// enough that one long-lived cell pins little memory.
pub const page_bytes: usize = 64 * 1024;

/// Largest cell served from pages. A larger cell goes to `infra`.
pub const max_small_bytes: usize = 4096;

/// Largest alignment served from pages. Slot sizes are multiples of 8 and the
/// first slot sits at a 64-byte offset, so every slot is 8-aligned.
pub const max_small_alignment: std.mem.Alignment = .@"8";

/// Size classes: 8-byte steps to 128, 16-byte steps to 512, then four per
/// power of two to 4096. A vector/map trie node (264 bytes) lands in the 272
/// class, 3 % waste; the worst case past 512 is 25 %, on cells that are rare.
pub const class_sizes = blk: {
    var sizes: [51]u32 = undefined;
    var n: usize = 0;
    var s: u32 = 16;
    while (s <= 128) : (s += 8) {
        sizes[n] = s;
        n += 1;
    }
    s = 144;
    while (s <= 512) : (s += 16) {
        sizes[n] = s;
        n += 1;
    }
    var base: u32 = 512;
    while (base < max_small_bytes) : (base *= 2) {
        var q: u32 = 1;
        while (q <= 4) : (q += 1) {
            sizes[n] = base + base / 4 * q;
            n += 1;
        }
    }
    if (n != sizes.len) @compileError("class_sizes table length mismatch");
    if (sizes[n - 1] != max_small_bytes) @compileError("class_sizes must end at max_small_bytes");
    break :blk sizes;
};

pub const class_count = class_sizes.len;

/// `(size + 7) / 8` -> class index, for every size up to 512.
const small_lookup = blk: {
    var table: [512 / 8 + 1]u8 = undefined;
    var c: usize = 0;
    for (&table, 0..) |*slot, i| {
        const size = @max(i * 8, 16);
        while (class_sizes[c] < size) c += 1;
        slot.* = @intCast(c);
    }
    break :blk table;
};

/// The class serving `size` bytes, or null when `size` is above
/// `max_small_bytes`.
pub fn classOf(size: usize) ?u8 {
    if (size <= 512) return small_lookup[(size + 7) / 8];
    if (size > max_small_bytes) return null;
    var c: usize = small_lookup[512 / 8];
    while (class_sizes[c] < size) c += 1;
    return @intCast(c);
}

/// True iff a cell of this size and alignment is served from pages.
pub fn isSmall(size: usize, alignment: std.mem.Alignment) bool {
    return size <= max_small_bytes and alignment.compare(.lte, max_small_alignment);
}

const FreeSlot = struct {
    next: ?*FreeSlot,
};

/// Header at offset 0 of every page.
const Page = struct {
    /// Every mapped page, for `release` and `deinit`.
    next_all: ?*Page,
    prev_all: ?*Page,
    /// The class's available list: pages with a free slot or unbumped space.
    next_avail: ?*Page,
    /// Freed slots of this page (link at slot offset 8).
    free: ?*FreeSlot,
    /// Offset of the next never-used slot.
    bump: u32,
    slot_size: u32,
    /// Live slots.
    used: u32,
    capacity: u32,
    class: u8,
    in_avail: bool,

    fn base(self: *Page) [*]u8 {
        return @ptrCast(self);
    }
};

/// First slot offset. 64 keeps every slot 8-aligned for any class size.
const first_slot: u32 = 64;

comptime {
    std.debug.assert(@sizeOf(Page) <= first_slot);
}

fn pageOf(ptr: [*]u8) *Page {
    return @ptrFromInt(@intFromPtr(ptr) & ~(page_bytes - 1));
}

pub const PageHeap = struct {
    /// Source of pages. `std.heap.page_allocator` in production (mmap/munmap,
    /// VirtualAlloc, or wasm memory); injectable so a test can count maps.
    source: std.mem.Allocator = std.heap.page_allocator,
    avail: [class_count]?*Page = @splat(null),
    all: ?*Page = null,
    /// Pages currently mapped.
    page_count: usize = 0,
    /// Lifetime totals, for `CLJW_GC_STATS`.
    pages_mapped_total: u64 = 0,
    pages_released_total: u64 = 0,

    pub fn mappedBytes(self: *const PageHeap) usize {
        return self.page_count * page_bytes;
    }

    /// Allocate one slot for a cell of `size` bytes (`isSmall` must hold).
    /// Returns null only when the OS refuses a new page.
    pub fn alloc(self: *PageHeap, size: usize) ?[*]u8 {
        const c = classOf(size).?;
        while (true) {
            const page = self.avail[c] orelse self.newPage(c) orelse return null;
            if (page.free) |slot| {
                page.free = slot.next;
                page.used += 1;
                return @as([*]u8, @ptrCast(slot)) - 8;
            }
            if (page.bump + page.slot_size <= page_bytes) {
                const p = page.base() + page.bump;
                page.bump += page.slot_size;
                page.used += 1;
                return p;
            }
            // Full: drop it from the available list. `free` re-adds it.
            self.avail[c] = page.next_avail;
            page.next_avail = null;
            page.in_avail = false;
        }
    }

    /// Return a slot to its page. The page stays mapped; `release` decides.
    pub fn free(self: *PageHeap, ptr: [*]u8) void {
        const page = pageOf(ptr);
        std.debug.assert(page.used > 0);
        const slot: *FreeSlot = @ptrCast(@alignCast(ptr + 8));
        slot.next = page.free;
        page.free = slot;
        page.used -= 1;
        if (!page.in_avail) {
            page.next_avail = self.avail[page.class];
            self.avail[page.class] = page;
            page.in_avail = true;
        }
    }

    /// After a sweep: unmap empty pages beyond `retain_bytes` of them, and
    /// rebuild every available list so partially used pages are filled before
    /// a retained empty one is touched (the empties then stay empty and are
    /// the first released next time). Returns the pages released.
    pub fn release(self: *PageHeap, retain_bytes: usize) usize {
        self.avail = @splat(null);
        var retained: usize = 0;
        var released: usize = 0;
        // Pass 1: empty pages. Keep up to the budget, unmap the rest.
        var it = self.all;
        while (it) |page| {
            it = page.next_all;
            if (page.used != 0) continue;
            if (retained + page_bytes <= retain_bytes) {
                retained += page_bytes;
                page.free = null;
                page.bump = first_slot;
                self.pushAvail(page);
            } else {
                self.unlinkAll(page);
                self.source.rawFree(page.base()[0..page_bytes], .fromByteUnits(page_bytes), @returnAddress());
                self.page_count -= 1;
                released += 1;
            }
        }
        // Pass 2: partially used pages go on top, so they are filled first.
        it = self.all;
        while (it) |page| {
            it = page.next_all;
            if (page.used == 0) continue;
            if (page.used < page.capacity) {
                self.pushAvail(page);
            } else {
                page.next_avail = null;
                page.in_avail = false;
            }
        }
        self.pages_released_total += released;
        return released;
    }

    pub fn deinit(self: *PageHeap) void {
        var it = self.all;
        while (it) |page| {
            it = page.next_all;
            self.source.rawFree(page.base()[0..page_bytes], .fromByteUnits(page_bytes), @returnAddress());
        }
        self.* = .{ .source = self.source };
    }

    fn pushAvail(self: *PageHeap, page: *Page) void {
        page.next_avail = self.avail[page.class];
        self.avail[page.class] = page;
        page.in_avail = true;
    }

    fn unlinkAll(self: *PageHeap, page: *Page) void {
        if (page.prev_all) |p| p.next_all = page.next_all else self.all = page.next_all;
        if (page.next_all) |n| n.prev_all = page.prev_all;
    }

    fn newPage(self: *PageHeap, c: u8) ?*Page {
        const mem = self.source.rawAlloc(page_bytes, .fromByteUnits(page_bytes), @returnAddress()) orelse return null;
        const page: *Page = @ptrCast(@alignCast(mem));
        const slot_size = class_sizes[c];
        page.* = .{
            .next_all = self.all,
            .prev_all = null,
            .next_avail = null,
            .free = null,
            .bump = first_slot,
            .slot_size = slot_size,
            .used = 0,
            .capacity = @intCast((page_bytes - first_slot) / slot_size),
            .class = c,
            .in_avail = false,
        };
        if (self.all) |head| head.prev_all = page;
        self.all = page;
        self.pushAvail(page);
        self.page_count += 1;
        self.pages_mapped_total += 1;
        return page;
    }
};

// --- tests ---

test "classOf: exact fit at every class, null past max_small_bytes" {
    for (class_sizes, 0..) |s, i| {
        try testing.expectEqual(@as(?u8, @intCast(i)), classOf(s));
        if (s > 16) try testing.expect(class_sizes[classOf(s - 1).?] >= s - 1);
    }
    try testing.expectEqual(@as(?u8, 0), classOf(1));
    try testing.expectEqual(@as(?u8, 0), classOf(16));
    try testing.expectEqual(@as(u32, 272), class_sizes[classOf(264).?]);
    try testing.expectEqual(@as(?u8, null), classOf(max_small_bytes + 1));
    // Monotone and always large enough.
    var size: usize = 1;
    while (size <= max_small_bytes) : (size += 1) {
        try testing.expect(class_sizes[classOf(size).?] >= size);
    }
}

test "PageHeap: freed slots are reused before a new page is mapped" {
    var ph: PageHeap = .{ .source = testing.allocator };
    defer ph.deinit();
    var ptrs: [1000][*]u8 = undefined;
    for (&ptrs) |*p| p.* = ph.alloc(264).?;
    const pages = ph.page_count;
    for (ptrs) |p| ph.free(p);
    for (&ptrs) |*p| p.* = ph.alloc(264).?;
    try testing.expectEqual(pages, ph.page_count);
}

test "PageHeap: release unmaps empty pages beyond the budget and keeps partial ones" {
    var ph: PageHeap = .{ .source = testing.allocator };
    defer ph.deinit();
    var ptrs: [2000][*]u8 = undefined;
    for (&ptrs) |*p| p.* = ph.alloc(64).?;
    const pages = ph.page_count;
    try testing.expect(pages >= 2);
    // Keep one cell alive: its page is partial, every other page empties.
    for (ptrs[1..]) |p| ph.free(p);
    try testing.expectEqual(pages - 1, ph.release(0));
    try testing.expectEqual(@as(usize, 1), ph.page_count);
    // The survivor's page serves the next allocation; no new page.
    _ = ph.alloc(64).?;
    try testing.expectEqual(@as(usize, 1), ph.page_count);
}

test "PageHeap: release keeps empty pages up to the retention budget" {
    var ph: PageHeap = .{ .source = testing.allocator };
    defer ph.deinit();
    var ptrs: [4000][*]u8 = undefined;
    for (&ptrs) |*p| p.* = ph.alloc(128).?;
    const pages = ph.page_count;
    for (ptrs) |p| ph.free(p);
    _ = ph.release(2 * page_bytes);
    try testing.expectEqual(@as(usize, 2), ph.page_count);
    try testing.expect(pages > 2);
    // Retained pages are reset to bump allocation and serve the next burst.
    for (ptrs[0..100]) |*p| p.* = ph.alloc(128).?;
    try testing.expectEqual(@as(usize, 2), ph.page_count);
}

test "PageHeap: classes do not share a page" {
    var ph: PageHeap = .{ .source = testing.allocator };
    defer ph.deinit();
    const a = ph.alloc(16).?;
    const b = ph.alloc(4096).?;
    try testing.expect(pageOf(a) != pageOf(b));
    try testing.expectEqual(@as(usize, 2), ph.page_count);
}
