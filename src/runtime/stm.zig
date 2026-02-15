// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! STM — Software Transactional Memory (LockingTransaction).
//!
//! Implements Clojure's MVCC STM for Ref types. Transactions provide:
//!   - Snapshot isolation (reads see consistent point-in-time)
//!   - Automatic retry on conflict
//!   - Commutative operations (commute)
//!   - Read-lock protection (ensure)
//!
//! Simplified from JVM Clojure's LockingTransaction:
//!   - No barge logic (simpler conflict resolution: just retry)
//!   - History chain but no adaptive growth (fixed at max_history)
//!   - Uses Zig mutex instead of ReentrantReadWriteLock

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const RefObj = value_mod.RefObj;
const RefInner = value_mod.RefInner;
const TVal = value_mod.TVal;
const err = @import("error.zig");
const bootstrap = @import("bootstrap.zig");

const RETRY_LIMIT: u32 = 10000;

/// Global transaction ordering counter.
var last_point: std.atomic.Value(i64) = std.atomic.Value(i64).init(0);

fn getCommitPoint() i64 {
    return last_point.fetchAdd(1, .monotonic) + 1;
}

fn getReadPoint() i64 {
    return last_point.load(.monotonic);
}

/// Per-thread current transaction (threadlocal).
threadlocal var current_tx: ?*LockingTransaction = null;

/// Check if the current thread is inside a transaction.
pub fn isInTransaction() bool {
    return current_tx != null;
}

/// Get the current thread's transaction, or null if none.
pub fn getCurrentTransaction() ?*LockingTransaction {
    return current_tx;
}

/// Commute function entry: fn + args to replay at commit time.
const CommuteFn = struct {
    func: Value,
    args: []const Value,
};

/// LockingTransaction — per-thread STM transaction state.
pub const LockingTransaction = struct {
    read_point: i64,
    vals: std.AutoHashMapUnmanaged(*RefInner, Value), // in-tx values
    sets: std.AutoHashMapUnmanaged(*RefInner, void), // explicitly set refs
    commutes: std.AutoHashMapUnmanaged(*RefInner, std.ArrayListUnmanaged(CommuteFn)),
    ensures: std.AutoHashMapUnmanaged(*RefInner, void), // ensured refs
    allocator: Allocator,

    pub fn init(allocator: Allocator) LockingTransaction {
        return .{
            .read_point = getReadPoint(),
            .vals = .empty,
            .sets = .empty,
            .commutes = .empty,
            .ensures = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LockingTransaction) void {
        self.vals.deinit(self.allocator);
        self.sets.deinit(self.allocator);
        // Free commute fn lists
        var it = self.commutes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.commutes.deinit(self.allocator);
        self.ensures.deinit(self.allocator);
    }

    fn reset(self: *LockingTransaction) void {
        self.vals.clearRetainingCapacity();
        self.sets.clearRetainingCapacity();
        var it = self.commutes.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.clearRetainingCapacity();
        }
        self.commutes.clearRetainingCapacity();
        self.ensures.clearRetainingCapacity();
        self.read_point = getReadPoint();
    }

    /// Run a transaction body function. Retries on conflict.
    pub fn runInTransaction(allocator: Allocator, body_fn: Value) anyerror!Value {
        // Nested transactions are a no-op (reuse outer transaction)
        if (current_tx != null) {
            return bootstrap.callFnVal(allocator, body_fn, &.{});
        }

        var tx = LockingTransaction.init(allocator);
        defer tx.deinit();

        var retry_count: u32 = 0;
        while (retry_count < RETRY_LIMIT) : (retry_count += 1) {
            tx.reset();
            current_tx = &tx;
            defer current_tx = null;

            // Execute the body
            const result = bootstrap.callFnVal(allocator, body_fn, &.{}) catch |e| {
                if (e == error.STMRetry) continue;
                return e;
            };

            // Commit phase
            tx.commit(allocator) catch |e| {
                if (e == error.STMRetry) continue;
                return e;
            };

            return result;
        }

        return err.setErrorFmt(.eval, .value_error, .{}, "Transaction failed after {d} retries", .{RETRY_LIMIT});
    }

    /// Read a ref's value within this transaction.
    pub fn doGet(self: *LockingTransaction, inner: *RefInner) anyerror!Value {
        // Check in-transaction cache first
        if (self.vals.get(inner)) |v| return v;

        // Walk history chain for version at or before read_point
        inner.lock.lock();
        defer inner.lock.unlock();

        var tval = inner.tvals;
        while (tval) |tv| {
            if (tv.point <= self.read_point) {
                return tv.val;
            }
            tval = tv.prior;
        }

        // No matching version found — retry (another tx committed after our read_point)
        return error.STMRetry;
    }

    /// Set a ref's value within this transaction.
    pub fn doSet(self: *LockingTransaction, inner: *RefInner, val: Value) !void {
        // Check for write-write conflict
        inner.lock.lock();
        if (inner.currentPoint() > self.read_point) {
            inner.lock.unlock();
            return error.STMRetry;
        }
        inner.lock.unlock();

        self.vals.put(self.allocator, inner, val) catch return error.OutOfMemory;
        self.sets.put(self.allocator, inner, {}) catch return error.OutOfMemory;
    }

    /// Commute: queue a function to be applied at commit time.
    pub fn doCommute(self: *LockingTransaction, allocator: Allocator, inner: *RefInner, func: Value, args: []const Value) anyerror!Value {
        // Get current in-transaction value (or read from ref)
        const current = self.vals.get(inner) orelse blk: {
            inner.lock.lock();
            defer inner.lock.unlock();
            break :blk inner.currentVal();
        };

        // Apply function immediately for in-transaction reads
        const call_args = try allocator.alloc(Value, args.len + 1);
        call_args[0] = current;
        @memcpy(call_args[1..], args);
        const new_val = try bootstrap.callFnVal(allocator, func, call_args);

        // Cache the result
        self.vals.put(self.allocator, inner, new_val) catch return error.OutOfMemory;

        // Queue the commute function for replay at commit
        const gop = self.commutes.getOrPut(self.allocator, inner) catch return error.OutOfMemory;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        const owned_args = try self.allocator.dupe(Value, args);
        gop.value_ptr.append(self.allocator, .{ .func = func, .args = owned_args }) catch return error.OutOfMemory;

        return new_val;
    }

    /// Ensure: protect a ref from writes by other transactions.
    pub fn doEnsure(self: *LockingTransaction, inner: *RefInner) !void {
        // If already set in this transaction, ensure is implicit
        if (self.sets.contains(inner)) return;

        inner.lock.lock();
        if (inner.currentPoint() > self.read_point) {
            inner.lock.unlock();
            return error.STMRetry;
        }
        inner.lock.unlock();

        self.ensures.put(self.allocator, inner, {}) catch return error.OutOfMemory;
    }

    /// Commit: apply all changes atomically.
    fn commit(self: *LockingTransaction, allocator: Allocator) !void {
        // Phase 1: Replay commutes against current committed values
        var commute_iter = self.commutes.iterator();
        while (commute_iter.next()) |entry| {
            const inner = entry.key_ptr.*;
            const cfns = entry.value_ptr.*;

            // Skip if also in sets (alter takes precedence)
            if (self.sets.contains(inner)) continue;

            inner.lock.lock();

            // Replay all commute fns against the current committed value
            var current = inner.currentVal();
            for (cfns.items) |cfn| {
                const call_args = try allocator.alloc(Value, cfn.args.len + 1);
                call_args[0] = current;
                @memcpy(call_args[1..], cfn.args);
                current = bootstrap.callFnVal(allocator, cfn.func, call_args) catch |e| {
                    inner.lock.unlock();
                    return e;
                };
            }

            self.vals.put(self.allocator, inner, current) catch {
                inner.lock.unlock();
                return error.OutOfMemory;
            };
            self.sets.put(self.allocator, inner, {}) catch {
                inner.lock.unlock();
                return error.OutOfMemory;
            };

            inner.lock.unlock();
        }

        // Phase 2: Validate and acquire locks on all modified refs
        // (Re-check that no ref has been modified since our read_point)
        var sets_iter = self.sets.iterator();
        while (sets_iter.next()) |entry| {
            const inner = entry.key_ptr.*;
            inner.lock.lock();
            if (inner.currentPoint() > self.read_point) {
                // Conflict — unlock all and retry
                self.unlockAll();
                return error.STMRetry;
            }
        }

        // Phase 3: Check ensures haven't been violated
        var ensures_iter = self.ensures.iterator();
        while (ensures_iter.next()) |entry| {
            const inner = entry.key_ptr.*;
            if (!self.sets.contains(inner)) {
                inner.lock.lock();
                if (inner.currentPoint() > self.read_point) {
                    self.unlockAll();
                    self.unlockEnsures();
                    return error.STMRetry;
                }
            }
        }

        // Phase 4a: Validate all new values before writing
        {
            var validate_iter = self.vals.iterator();
            while (validate_iter.next()) |entry| {
                const inner = entry.key_ptr.*;
                const new_val = entry.value_ptr.*;
                if (self.sets.contains(inner)) {
                    if (inner.validator) |validator| {
                        const valid = bootstrap.callFnVal(allocator, validator, &.{new_val}) catch {
                            self.unlockAll();
                            self.unlockEnsures();
                            return err.setErrorFmt(.eval, .value_error, .{}, "Invalid reference state", .{});
                        };
                        if (!valid.isTruthy()) {
                            self.unlockAll();
                            self.unlockEnsures();
                            return err.setErrorFmt(.eval, .value_error, .{}, "Invalid reference state", .{});
                        }
                    }
                }
            }
        }

        // Phase 4b: Commit — create new TVal entries (validators passed)
        const commit_point = getCommitPoint();
        var vals_iter = self.vals.iterator();
        while (vals_iter.next()) |entry| {
            const inner = entry.key_ptr.*;
            const new_val = entry.value_ptr.*;

            if (self.sets.contains(inner)) {
                const tv = std.heap.smp_allocator.create(TVal) catch {
                    self.unlockAll();
                    self.unlockEnsures();
                    return error.OutOfMemory;
                };
                tv.* = .{
                    .val = new_val,
                    .point = commit_point,
                    .prior = inner.tvals,
                };
                inner.tvals = tv;
                trimHistory(inner);
            }
        }

        // Phase 5: Unlock all
        self.unlockAll();
        self.unlockEnsures();

        // Phase 6: Notify watchers (outside locks)
        var watch_iter = self.vals.iterator();
        while (watch_iter.next()) |entry| {
            const inner = entry.key_ptr.*;
            notifyWatches(allocator, inner, entry.value_ptr.*);
        }
    }

    fn unlockAll(self: *LockingTransaction) void {
        var it = self.sets.iterator();
        while (it.next()) |entry| {
            entry.key_ptr.*.lock.unlock();
        }
    }

    fn unlockEnsures(self: *LockingTransaction) void {
        var it = self.ensures.iterator();
        while (it.next()) |entry| {
            if (!self.sets.contains(entry.key_ptr.*)) {
                entry.key_ptr.*.lock.unlock();
            }
        }
    }
};

/// Trim ref history to max_history entries.
fn trimHistory(inner: *RefInner) void {
    if (inner.max_history == 0) return;
    var count: u32 = 0;
    var prev: ?*TVal = null;
    var tval = inner.tvals;
    while (tval) |tv| {
        count += 1;
        if (count >= inner.max_history) {
            // Cut the chain here
            if (prev) |p| p.prior = null;
            break;
        }
        prev = tv;
        tval = tv.prior;
    }
}

/// Notify watchers for a ref.
fn notifyWatches(allocator: Allocator, inner: *RefInner, new_val: Value) void {
    if (inner.watch_count == 0) return;
    const keys = inner.watch_keys orelse return;
    const fns = inner.watch_fns orelse return;
    // Get the old value (prior to the newest TVal)
    const old_val = if (inner.tvals) |tv| (if (tv.prior) |p| p.val else Value.nil_val) else Value.nil_val;
    for (0..inner.watch_count) |i| {
        // (watch-fn key ref old-val new-val) — but we don't have the ref Value here
        // For now, just call (watch-fn key nil old-val new-val)
        _ = bootstrap.callFnVal(allocator, fns[i], &.{ keys[i], Value.nil_val, old_val, new_val }) catch {};
    }
}

/// Create a new Ref with initial value.
pub fn createRef(allocator: Allocator, initial_val: Value, opts: RefOptions) !Value {
    const inner = std.heap.smp_allocator.create(RefInner) catch return error.OutOfMemory;

    // Create initial TVal
    const tv = std.heap.smp_allocator.create(TVal) catch return error.OutOfMemory;
    tv.* = .{
        .val = initial_val,
        .point = getCommitPoint(),
        .prior = null,
    };

    inner.* = .{
        .tvals = tv,
        .faults = 0,
        .min_history = opts.min_history,
        .max_history = opts.max_history,
        .lock = .{},
        .tinfo = null,
        .validator = opts.validator,
        .meta_val = opts.meta orelse Value.nil_val,
        .watch_keys = null,
        .watch_fns = null,
        .watch_count = 0,
    };

    const ref_obj = try allocator.create(RefObj);
    ref_obj.* = .{ .inner = @ptrCast(inner) };
    return Value.initRef(ref_obj);
}

pub const RefOptions = struct {
    min_history: u32 = 0,
    max_history: u32 = 10,
    validator: ?Value = null,
    meta: ?Value = null,
};

// Tests
const testing = std.testing;

test "STM — createRef and deref" {
    const allocator = testing.allocator;
    const ref_val = try createRef(allocator, Value.initInteger(42), .{});
    try testing.expect(ref_val.tag() == .ref);
    const inner: *RefInner = @ptrCast(@alignCast(ref_val.asRef().inner));
    try testing.expectEqual(@as(i64, 42), inner.currentVal().asInteger());
    allocator.destroy(ref_val.asRef());
}

test "STM — getReadPoint and getCommitPoint ordering" {
    const p1 = getCommitPoint();
    const p2 = getCommitPoint();
    const rp = getReadPoint();
    try testing.expect(p2 > p1);
    try testing.expect(rp >= p2);
}
