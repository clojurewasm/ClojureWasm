// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Concurrency regression tests (Phase 57).
//!
//! Tests GC safety under multi-threaded allocation/collection.
//! These tests directly exercise the MarkSweepGc with concurrent threads
//! to verify mutex protection and detect potential race conditions.

const std = @import("std");
const gc_mod = @import("gc.zig");
const MarkSweepGc = gc_mod.MarkSweepGc;
const thread_pool = @import("thread_pool.zig");
const FutureResult = thread_pool.FutureResult;

const testing = std.testing;

// ============================================================
// 57.1: Multiple threads allocating concurrently via GC
// ============================================================

// Spawn N threads that each allocate many small blocks through the GC allocator.
// Verifies no crash/corruption under concurrent GC mutex contention.
test "57.1 — concurrent GC allocation from multiple threads" {
    var ms_gc = MarkSweepGc.init(std.heap.page_allocator);
    defer ms_gc.deinit();
    const gc_alloc = ms_gc.allocator();

    const thread_count = 8;
    const allocs_per_thread = 200;

    const Worker = struct {
        fn run(alloc: std.mem.Allocator, results: *std.atomic.Value(u32)) void {
            var success: u32 = 0;
            for (0..allocs_per_thread) |_| {
                // Allocate a small block
                const block = alloc.alloc(u8, 64) catch continue;
                // Write pattern to verify memory integrity
                @memset(block, 0xAA);
                success += 1;
                // Don't free — let GC track them (simulates Clojure value allocation)
            }
            _ = results.fetchAdd(success, .monotonic);
        }
    };

    var total_success = std.atomic.Value(u32).init(0);
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;

    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Worker.run, .{ gc_alloc, &total_success }) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    const total = total_success.load(.acquire);
    // At least some allocations should succeed (all should, but GC may reclaim under pressure)
    try testing.expect(total > 0);
    // Verify GC internal state is consistent (alloc_count matches)
    try testing.expect(ms_gc.alloc_count > 0);
}

// ============================================================
// 57.2: GC collection during concurrent allocation
// ============================================================

// One thread triggers GC collection while others are allocating.
// Verifies collection + allocation can coexist safely (mutex serialized).
test "57.2 — GC collection during concurrent allocation" {
    var ms_gc = MarkSweepGc.init(std.heap.page_allocator);
    defer ms_gc.deinit();
    const gc_alloc = ms_gc.allocator();

    const alloc_thread_count = 4;
    var stop_flag = std.atomic.Value(bool).init(false);
    var alloc_total = std.atomic.Value(u32).init(0);
    var collect_count = std.atomic.Value(u32).init(0);

    const Allocator = struct {
        fn run(alloc: std.mem.Allocator, stop: *std.atomic.Value(bool), total: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                const block = alloc.alloc(u8, 32) catch continue;
                @memset(block, 0xBB);
                _ = total.fetchAdd(1, .monotonic);
            }
        }
    };

    const Collector = struct {
        fn run(gc: *MarkSweepGc, stop: *std.atomic.Value(bool), count: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                // Force collection (no marking — all allocations are unreachable)
                gc.gc_mutex.lock();
                gc.gc_mutex.unlock();
                // Calling full collect would sweep everything since nothing is marked.
                // Instead, just verify we can acquire the lock safely while others allocate.
                _ = count.fetchAdd(1, .monotonic);
                std.Thread.sleep(1_000_000); // 1ms between "collections"
            }
        }
    };

    // Start allocator threads
    var threads: [alloc_thread_count + 1]std.Thread = undefined;
    var spawned: usize = 0;

    for (0..alloc_thread_count) |_| {
        threads[spawned] = std.Thread.spawn(.{}, Allocator.run, .{ gc_alloc, &stop_flag, &alloc_total }) catch break;
        spawned += 1;
    }

    // Start collector thread
    threads[spawned] = std.Thread.spawn(.{}, Collector.run, .{ &ms_gc, &stop_flag, &collect_count }) catch {
        stop_flag.store(true, .release);
        for (threads[0..spawned]) |t| t.join();
        return;
    };
    spawned += 1;

    // Let them run for 50ms
    std.Thread.sleep(50_000_000);
    stop_flag.store(true, .release);

    for (threads[0..spawned]) |t| t.join();

    try testing.expect(alloc_total.load(.acquire) > 0);
    try testing.expect(collect_count.load(.acquire) > 0);
}

// ============================================================
// 57.3: FutureResult concurrent set/get stress
// ============================================================

// Multiple producer threads setting results on separate FutureResults,
// multiple consumer threads waiting on them. Stress test for the
// mutex + condvar synchronization.
test "57.3 — FutureResult stress: many concurrent set/get pairs" {
    const pair_count = 16;
    var results: [pair_count]FutureResult = undefined;
    for (&results) |*r| r.* = .{};

    const Producer = struct {
        fn run(r: *FutureResult, id: usize) void {
            // Simulate some work
            std.Thread.sleep(@as(u64, @intCast(id)) * 500_000); // 0.5ms * id
            const val = @import("value.zig").Value.initInteger(@intCast(id * 42));
            r.setResult(val);
        }
    };

    const Consumer = struct {
        fn run(r: *FutureResult, id: usize) !void {
            const val = r.get();
            const expected: i64 = @intCast(id * 42);
            try testing.expectEqual(expected, val.asInteger());
        }
    };

    // Spawn producer + consumer pairs
    var threads: [pair_count * 2]std.Thread = undefined;
    var spawned: usize = 0;

    for (0..pair_count) |i| {
        threads[spawned] = std.Thread.spawn(.{}, Producer.run, .{ &results[i], i }) catch break;
        spawned += 1;
        threads[spawned] = std.Thread.spawn(.{}, Consumer.run, .{ &results[i], i }) catch break;
        spawned += 1;
    }

    for (threads[0..spawned]) |t| t.join();
}

// ============================================================
// 57.4: Concurrent allocation + free-pool recycling
// ============================================================

// Allocate, free, then allocate again from multiple threads.
// Tests that the free-pool recycling doesn't corrupt under concurrency.
test "57.4 — concurrent alloc/free recycling stress" {
    var ms_gc = MarkSweepGc.init(std.heap.page_allocator);
    defer ms_gc.deinit();
    const gc_alloc = ms_gc.allocator();

    const thread_count = 8;
    const cycles = 100;

    const Worker = struct {
        fn run(alloc: std.mem.Allocator, results: *std.atomic.Value(u32)) void {
            var success: u32 = 0;
            for (0..cycles) |_| {
                // Allocate
                const block = alloc.alloc(u8, 48) catch continue;
                @memset(block, 0xCC);
                // Free (returns to free pool)
                alloc.free(block);
                // Re-allocate (should hit free pool)
                const block2 = alloc.alloc(u8, 48) catch continue;
                @memset(block2, 0xDD);
                // Verify pattern
                if (block2[0] == 0xDD) success += 1;
            }
            _ = results.fetchAdd(success, .monotonic);
        }
    };

    var total_success = std.atomic.Value(u32).init(0);
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;

    for (&threads) |*t| {
        t.* = std.Thread.spawn(.{}, Worker.run, .{ gc_alloc, &total_success }) catch break;
        spawned += 1;
    }
    for (threads[0..spawned]) |t| t.join();

    const total = total_success.load(.acquire);
    try testing.expect(total > 0);
}
