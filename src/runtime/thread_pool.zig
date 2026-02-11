// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Thread pool for concurrent Clojure evaluation.
//!
//! Fixed-size pool backed by std.Thread. Worker threads share the namespace
//! registry (Env.namespaces) but have their own current_ns and binding frames.
//! Used by future, pmap, pcalls, pvalues (Phase 48).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const env_mod = @import("env.zig");
const gc_mod = @import("gc.zig");
const var_mod = @import("var.zig");
const bootstrap = @import("bootstrap.zig");
const ns_mod = @import("namespace.zig");

/// Result of an asynchronous computation.
///
/// Thread-safe: guarded by internal mutex + condition variable.
/// deref blocks until result is available (or timeout).
pub const FutureResult = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    state: State = .pending,
    value: Value = Value.nil_val,
    err_value: Value = Value.nil_val,

    pub const State = enum { pending, done, @"error" };

    /// Block until result is available, then return it.
    pub fn get(self: *FutureResult) Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.state == .pending) {
            self.cond.wait(&self.mutex);
        }
        return self.value;
    }

    /// Block until result is available or timeout (nanoseconds).
    /// Returns null on timeout.
    pub fn getWithTimeout(self: *FutureResult, timeout_ns: u64) ?Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.state != .pending) return self.value;
        self.cond.timedWait(&self.mutex, timeout_ns) catch {};
        if (self.state != .pending) return self.value;
        return null;
    }

    /// Check if result is available without blocking.
    pub fn isDone(self: *FutureResult) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state != .pending;
    }

    /// Set successful result and wake all waiters.
    pub fn setResult(self: *FutureResult, val: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.value = val;
        self.state = .done;
        self.cond.broadcast();
    }

    /// Set error result and wake all waiters.
    pub fn setError(self: *FutureResult, err_val: Value) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.err_value = err_val;
        self.state = .@"error";
        self.cond.broadcast();
    }
};

/// Work item submitted to the thread pool.
const WorkItem = struct {
    func: Value,
    result: *FutureResult,
    /// Namespace to set as current_ns in the worker thread.
    parent_ns: ?*ns_mod.Namespace,
    /// Parent's binding frame to convey to the worker (F6).
    parent_bindings: ?*var_mod.BindingFrame,
};

/// Fixed-size thread pool for concurrent Clojure evaluation.
///
/// Design (D94): Workers share the Env's namespace registry via shallow
/// clone. Each worker has its own current_ns (from parent at submit time),
/// binding frames (conveyed from parent), and threadlocal state.
/// GC is shared and mutex-protected (48.2).
///
/// IMPORTANT: Pool internals (threads array, work queue, pool struct itself)
/// are allocated via page_allocator, NOT the GC allocator. This prevents
/// the GC from sweeping the thread handles during collection.
pub const ThreadPool = struct {
    threads: []std.Thread,
    queue_mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    work_items: std.ArrayList(WorkItem),
    shutdown_flag: std.atomic.Value(bool),
    source_env: *env_mod.Env,

    /// Non-GC allocator for pool internals (thread handles, work queue).
    const pool_allocator = std.heap.page_allocator;

    /// Initialize thread pool with `thread_count` worker threads.
    /// Workers share `source_env` for namespace resolution.
    pub fn init(source_env: *env_mod.Env, thread_count: usize) !*ThreadPool {
        const pool = try pool_allocator.create(ThreadPool);
        pool.* = .{
            .threads = &.{},
            .work_items = .empty,
            .shutdown_flag = std.atomic.Value(bool).init(false),
            .source_env = source_env,
        };
        const count = if (thread_count == 0) getDefaultThreadCount() else thread_count;
        const threads = try pool_allocator.alloc(std.Thread, count);
        var spawned: usize = 0;
        errdefer {
            pool.shutdown_flag.store(true, .release);
            pool.queue_cond.broadcast();
            for (threads[0..spawned]) |t| t.join();
            pool_allocator.free(threads);
            pool_allocator.destroy(pool);
        }
        for (threads) |*t| {
            t.* = try std.Thread.spawn(.{}, workerLoop, .{pool});
            spawned += 1;
        }
        pool.threads = threads;
        return pool;
    }

    /// Submit a nullary Clojure function for async execution.
    /// Returns a FutureResult that can be deref'd for the result.
    pub fn submit(self: *ThreadPool, func: Value) !*FutureResult {
        const result = try pool_allocator.create(FutureResult);
        result.* = .{};

        // Capture parent thread's current namespace and bindings
        const parent_ns = if (bootstrap.macro_eval_env) |env| env.current_ns else null;
        const parent_bindings = var_mod.getCurrentBindingFrame();

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        try self.work_items.append(pool_allocator, .{
            .func = func,
            .result = result,
            .parent_ns = parent_ns,
            .parent_bindings = parent_bindings,
        });
        self.queue_cond.signal();
        return result;
    }

    /// Shut down the pool: signal workers to exit, then join all threads.
    pub fn shutdown(self: *ThreadPool) void {
        self.shutdown_flag.store(true, .release);
        // Wake all waiting workers
        {
            self.queue_mutex.lock();
            defer self.queue_mutex.unlock();
            self.queue_cond.broadcast();
        }
        for (self.threads) |t| {
            t.join();
        }
        self.work_items.deinit(pool_allocator);
        pool_allocator.free(self.threads);
        pool_allocator.destroy(self);
    }

    fn workerLoop(pool: *ThreadPool) void {
        // Register with GC thread registry
        gc_mod.thread_registry.registerThread();
        defer gc_mod.thread_registry.unregisterThread();

        // Set up per-thread env (shallow clone of source)
        var thread_env = pool.source_env.threadClone();
        bootstrap.macro_eval_env = &thread_env;
        defer bootstrap.macro_eval_env = null;

        // Get GC allocator for Clojure value allocation
        const gc_ptr: *gc_mod.MarkSweepGc = @ptrCast(@alignCast(pool.source_env.gc orelse return));
        const gc_alloc = gc_ptr.allocator();

        while (true) {
            // Get next work item (blocking)
            pool.queue_mutex.lock();
            while (pool.work_items.items.len == 0) {
                if (pool.shutdown_flag.load(.acquire)) {
                    pool.queue_mutex.unlock();
                    return;
                }
                pool.queue_cond.wait(&pool.queue_mutex);
            }
            const item = pool.work_items.orderedRemove(0);
            pool.queue_mutex.unlock();

            // Set up thread context from parent
            thread_env.current_ns = item.parent_ns;
            if (item.parent_bindings) |bindings| {
                var_mod.setCurrentBindingFrame(bindings);
            }

            // Execute the Clojure function (nullary)
            const result = bootstrap.callFnVal(gc_alloc, item.func, &.{}) catch {
                const err_val = bootstrap.last_thrown_exception orelse Value.nil_val;
                item.result.setError(err_val);
                continue;
            };
            item.result.setResult(result);
        }
    }

    fn getDefaultThreadCount() usize {
        return std.Thread.getCpuCount() catch 4;
    }
};

/// Global thread pool instance. Initialized lazily on first future/pmap call.
var global_pool: ?*ThreadPool = null;
var pool_mutex: std.Thread.Mutex = .{};

/// Get or create the global thread pool.
pub fn getGlobalPool(env: *env_mod.Env) !*ThreadPool {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    if (global_pool) |pool| return pool;
    const pool = try ThreadPool.init(env, 0);
    global_pool = pool;
    return pool;
}

/// Shut down the global thread pool (call at program exit).
pub fn shutdownGlobalPool() void {
    pool_mutex.lock();
    const pool = global_pool orelse {
        pool_mutex.unlock();
        return;
    };
    global_pool = null;
    pool_mutex.unlock();
    pool.shutdown();
}

// === Tests ===

test "FutureResult — set and get" {
    var result: FutureResult = .{};
    result.setResult(Value.initInteger(42));
    try std.testing.expectEqual(@as(i64, 42), result.get().asInteger());
}

test "FutureResult — isDone" {
    var result: FutureResult = .{};
    try std.testing.expect(!result.isDone());
    result.setResult(Value.nil_val);
    try std.testing.expect(result.isDone());
}

test "FutureResult — getWithTimeout returns null on timeout" {
    var result: FutureResult = .{};
    // 1ms timeout — no producer, should return null
    const val = result.getWithTimeout(1_000_000);
    try std.testing.expect(val == null);
}

test "FutureResult — concurrent set and get" {
    var result: FutureResult = .{};
    // Spawn a thread that sets the result after a brief delay
    const t = try std.Thread.spawn(.{}, struct {
        fn run(r: *FutureResult) void {
            std.Thread.sleep(5_000_000); // 5ms
            r.setResult(Value.initInteger(99));
        }
    }.run, .{&result});
    // get() should block until the thread sets the result
    const val = result.get();
    try std.testing.expectEqual(@as(i64, 99), val.asInteger());
    t.join();
}
