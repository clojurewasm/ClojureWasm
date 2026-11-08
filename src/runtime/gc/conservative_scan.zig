// SPDX-License-Identifier: EPL-2.0
//! D-556: conservative scan of the collecting thread's native stack for live
//! heap Values (tree_walk backend only; the vm's operand stack is the A1 root).
//!
//! Range: from the collector's own frame (deep) up to
//! `root_set.conservative_stack_top` (the shallowest tree_walk eval entry; 0
//! means tree_walk never ran on this thread, so skip). Each 8-byte word is
//! decoded via the `Value.heapHeader()` membrane (tag check only, no deref)
//! and pinned IFF the pointer matches a live allocation record. A stale word
//! that happens to look like a heap tag can only pin a still-live object (one
//! delayed free), never deref a dangling pointer. The live-pointer set is
//! built in one pass over `allocations` on `gc.infra` (never `gc.alloc`:
//! collect must not re-enter the heap).
//!
//! Compiled only under `-Dbackend=tree_walk`; vm builds get the no-op branch.

const std = @import("std");
const build_options = @import("build_options");
const GcHeap = @import("gc_heap.zig").GcHeap;
const root_set_mod = @import("root_set.zig");
const mark = @import("mark_sweep.zig").mark;

pub const ConservativeScan = if (build_options.backend == .tree_walk) struct {
    /// libc setjmp used ONLY as a register spill (Boehm GC's `GC_push_regs`
    /// idiom): it writes every callee-saved register into the buffer, so a
    /// heap Value living only in a callee-saved register becomes scannable.
    /// We never longjmp.
    extern fn setjmp(env: *anyopaque) c_int;

    /// Decode one candidate word and pin it if it is a live heap Value.
    inline fn pinIfLiveWord(gc: *GcHeap, live: *const std.AutoHashMapUnmanaged(usize, void), word: u64) void {
        const Value = @import("../value/value.zig").Value;
        const nb = @import("../value/nan_box.zig");
        // Pre-filter a zero address: `heapHeader`'s decodePtr would cast it to
        // a null pointer (a ReleaseSafe panic).
        if (word & nb.NB_ADDR_SHIFTED_MASK == 0) return;
        const v: Value = @enumFromInt(word);
        const hdr = v.heapHeader() orelse return;
        if (live.contains(@intFromPtr(hdr))) mark(gc, hdr);
    }

    pub fn run(gc: *GcHeap) void {
        const top = root_set_mod.conservative_stack_top;
        if (top == 0) return;
        const bottom = @frameAddress();
        if (bottom >= top) return;
        var live: std.AutoHashMapUnmanaged(usize, void) = .empty;
        defer live.deinit(gc.infra);
        live.ensureTotalCapacity(gc.infra, @intCast(gc.allocations.items.len)) catch return;
        for (gc.allocations.items) |rec| live.putAssumeCapacity(@intFromPtr(rec.header), {});
        // Registers first: 128 u64s comfortably hold any ABI's jmp_buf;
        // unwritten tail words stay zero and are filtered.
        var jb: [128]u64 align(16) = [_]u64{0} ** 128;
        _ = setjmp(@ptrCast(&jb));
        for (jb) |word| pinIfLiveWord(gc, &live, word);
        // Then the native stack from the collector's frame up to the anchor.
        var addr = std.mem.alignForward(usize, bottom, @alignOf(u64));
        while (addr + @sizeOf(u64) <= top) : (addr += @sizeOf(u64)) {
            pinIfLiveWord(gc, &live, @as(*const u64, @ptrFromInt(addr)).*);
        }
    }
} else struct {
    pub fn run(_: *GcHeap) void {
        // vm backend: precise root_set only; no conservative native-stack scan.
    }
};
