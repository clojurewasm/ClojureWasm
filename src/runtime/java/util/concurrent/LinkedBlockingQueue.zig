// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.LinkedBlockingQueue` — a bounded
//! FIFO queue over a `.host_instance` (ADR-0106), backed by a cljw VECTOR
//! Value the way `java.util.ArrayDeque` is, so the descriptor's `host_trace`
//! marks the one Value each GC and no `host_finalise` is needed.
//!
//! Backend: impl-only
//! Impl deps: host_instance, vector, equal, eval_budget, future, clock
//! Clojure peer: none
//!
//! state[0] = the backing vector, state[1] = capacity (0 = unbounded),
//! state[2] = head index, state[3] = the spin lock guarding a read-modify-
//! write of the other three.
//!
//! The head INDEX is what makes the queue a queue. `vector.copyRange` is an
//! O(n) eager copy (a materializing slice, deliberately NOT the `subvec` view —
//! compaction must DROP the drained prefix, and a view would retain it), so
//! dequeuing by rebuilding from index 1 would make draining a 256-slot work
//! queue quadratic, on the hottest path a thread pool has. Instead `.poll`
//! hands back `nth(v, head)` and bumps the head; the vector is COMPACTED (one
//! copyRange) only once the dead prefix is at least half of it, which amortises
//! to O(1) per element and bounds the garbage the prefix retains.
//!
//! Surface: `<init>` ([capacity]), `.offer` ([x] | [x timeout unit]), `.put`,
//! `.poll` ([] | [timeout unit]), `.take`, `.peek`, `.size`, `.isEmpty`,
//! `.remainingCapacity`, `.remove` ([] | [x]), `.contains`, `.clear`,
//! `.toArray`, `.drainTo`.
//!
//! A blocking wait polls in slices through `eval_budget.budgetedSleep` — the
//! same wait `Thread/sleep` and `Semaphore.acquire` own — so future-cancel and
//! the eval budget cut it short. The spin lock is NEVER held across a sleep:
//! every blocking op is a retry loop around the non-blocking one.

const std = @import("std");
const atomics = @import("../../../atomics.zig");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const host_instance = @import("../../../host_instance.zig");
const vector_mod = @import("../../../collection/vector.zig");
const equal = @import("../../../equal.zig");
const eval_budget = @import("../../../concurrency/eval_budget.zig");
const safepoint = @import("../../../concurrency/safepoint.zig");
const future = @import("../../../future.zig");
const clock = @import("../../../clock.zig");
const TimeUnit = @import("TimeUnit.zig");
const mark_sweep = @import("../../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../../gc/gc_heap.zig");

var lbq_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// Longest single wait slice; a shorter remaining deadline shortens the last.
const SLICE_NS: u64 = std.time.ns_per_ms;

/// Dead-prefix threshold: compact once the head has passed this many slots AND
/// the prefix is at least half the backing vector.
const COMPACT_MIN: u32 = 32;

fn vecOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}

fn setVec(recv: Value, v: Value) void {
    host_instance.setState(recv, 0, @intFromEnum(v));
}

fn capOf(recv: Value) u32 {
    return @truncate(host_instance.asHostInstance(recv).state[1]);
}

fn headOf(recv: Value) u32 {
    return @truncate(host_instance.asHostInstance(recv).state[2]);
}

fn setHead(recv: Value, h: u32) void {
    host_instance.setState(recv, 2, @as(u64, h));
}

fn lockPtr(recv: Value) *u64 {
    return &@constCast(host_instance.asHostInstance(recv)).state[3];
}

/// Take the per-instance spin lock. Critical sections are a handful of vector
/// ops, so spinning beats parking. `contains` and `remove` hold it across a
/// user `=`, which can collect, so the spin is a safepoint.
fn lock(recv: Value) void {
    const p = lockPtr(recv);
    while (atomics.cmpxchgWeak(u64, p, 0, 1, .acquire, .monotonic) != null) {
        safepoint.poll();
        std.atomic.spinLoopHint();
    }
}

fn unlock(recv: Value) void {
    atomics.store(u64, lockPtr(recv), 0, .release);
}

/// Live element count. Caller holds the lock.
fn sizeLocked(recv: Value) u32 {
    return vector_mod.count(vecOf(recv)) - headOf(recv);
}

/// Enqueue without blocking. False when a bounded queue is full.
pub fn tryOffer(rt: *Runtime, recv: Value, x: Value) !bool {
    lock(recv);
    defer unlock(recv);
    const cap = capOf(recv);
    if (cap != 0 and sizeLocked(recv) >= cap) return false;
    setVec(recv, try vector_mod.conj(rt, vecOf(recv), x));
    return true;
}

/// Dequeue without blocking. Null when empty. Compacts the dead prefix once it
/// dominates the backing vector, so the retained garbage stays bounded.
pub fn tryPoll(rt: *Runtime, recv: Value) !?Value {
    lock(recv);
    defer unlock(recv);
    const v = vecOf(recv);
    const n = vector_mod.count(v);
    const head = headOf(recv);
    if (head >= n) return null;
    const x = vector_mod.nth(v, head);
    const next = head + 1;
    if (next >= n) {
        // Drained: drop the whole backing vector so nothing stays reachable.
        setVec(recv, vector_mod.empty());
        setHead(recv, 0);
    } else if (next >= COMPACT_MIN and next * 2 >= n) {
        setVec(recv, try vector_mod.copyRange(rt, v, next, n));
        setHead(recv, 0);
    } else {
        setHead(recv, next);
    }
    return x;
}

/// Sleep one slice of a bounded (or unbounded) wait. Returns false when the
/// deadline has passed; raises when the worker is cancelled.
fn waitSlice(rt: *Runtime, deadline_ns: ?i64) !bool {
    if (deadline_ns) |deadline| {
        const remaining = deadline - clock.nanoTime(rt.io);
        if (remaining <= 0) return false;
        const slice = @min(@as(u64, @intCast(remaining)), SLICE_NS);
        try eval_budget.budgetedSleep(rt.io, slice, future.currentCancelLatch());
    } else {
        try eval_budget.budgetedSleep(rt.io, SLICE_NS, future.currentCancelLatch());
    }
    if (future.cancelRequested()) return error_catalog.raise(.future_cancel_abort, .{}, .{});
    return true;
}

/// The `timeout`/`unit` pair two args in, as a deadline. Null unit → error.
fn deadlineFrom(rt: *Runtime, args: []const Value, timeout_idx: usize, name: []const u8, loc: SourceLocation) !?i64 {
    const timeout = try error_catalog.expectInteger(args[timeout_idx], name, loc);
    const unit_val = args[timeout_idx + 1];
    const ns = TimeUnit.nanosOf(unit_val, @intCast(timeout)) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "a java.util.concurrent.TimeUnit", .actual = @tagName(unit_val.tag()) });
    if (ns <= 0) return null; // already expired — one non-blocking attempt only
    return clock.nanoTime(rt.io) +| ns;
}

/// `(java.util.concurrent.LinkedBlockingQueue.)` unbounded /
/// `(… capacity)` bounded.
fn initQueue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len > 1)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.concurrent.LinkedBlockingQueue.", .expected = 1 });
    var cap: u64 = 0;
    if (args.len == 1) {
        const n = try error_catalog.expectInteger(args[0], "java.util.concurrent.LinkedBlockingQueue.", loc);
        if (n <= 0)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.concurrent.LinkedBlockingQueue.", .expected = "a positive capacity", .actual = "a non-positive capacity" });
        cap = @intCast(n);
    }
    return make(rt, cap);
}

pub fn make(rt: *Runtime, capacity: u64) !Value {
    const td = lbq_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromEnum(vector_mod.empty()), capacity, 0, 0 });
}

pub fn isQueue(v: Value) bool {
    if (v.tag() != .host_instance) return false;
    const fqcn = host_instance.asHostInstance(v).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fqcn, "java.util.concurrent.LinkedBlockingQueue");
}

/// `(.offer q x)` immediate / `(.offer q x timeout unit)` timed.
fn offer(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange(".offer", args, 2, 4, loc);
    if (args.len == 2) return Value.initBoolean(try tryOffer(rt, args[0], args[1]));
    if (args.len != 4)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = ".offer", .expected = 4 });
    const deadline = try deadlineFrom(rt, args, 2, ".offer", loc);
    while (true) {
        if (try tryOffer(rt, args[0], args[1])) return Value.initBoolean(true);
        if (deadline == null) return Value.initBoolean(false);
        if (!try waitSlice(rt, deadline)) return Value.initBoolean(false);
    }
}

/// `(.put q x)` — block until there is room. Returns nil (JVM put is void).
fn put(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".put", args, 2, loc);
    while (!try tryOffer(rt, args[0], args[1]))
        _ = try waitSlice(rt, null);
    return Value.nil_val;
}

/// `(.poll q)` immediate / `(.poll q timeout unit)` timed. nil when empty.
fn poll(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange(".poll", args, 1, 3, loc);
    if (args.len == 1) return (try tryPoll(rt, args[0])) orelse Value.nil_val;
    if (args.len != 3)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = ".poll", .expected = 3 });
    const deadline = try deadlineFrom(rt, args, 1, ".poll", loc);
    while (true) {
        if (try tryPoll(rt, args[0])) |x| return x;
        if (deadline == null) return Value.nil_val;
        if (!try waitSlice(rt, deadline)) return Value.nil_val;
    }
}

/// `(.take q)` — block until an element is available.
fn take(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".take", args, 1, loc);
    while (true) {
        if (try tryPoll(rt, args[0])) |x| return x;
        _ = try waitSlice(rt, null);
    }
}

/// `(.peek q)` — the head without removing it, or nil.
fn peek(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".peek", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    const v = vecOf(args[0]);
    const head = headOf(args[0]);
    if (head >= vector_mod.count(v)) return Value.nil_val;
    return vector_mod.nth(v, head);
}

fn size(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".size", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    return Value.initInteger(@intCast(sizeLocked(args[0])));
}

fn isEmpty(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isEmpty", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    return Value.initBoolean(sizeLocked(args[0]) == 0);
}

/// `(.remainingCapacity q)` — an unbounded queue reports `Integer/MAX_VALUE`,
/// as the JVM's does.
fn remainingCapacity(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".remainingCapacity", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    const cap = capOf(args[0]);
    if (cap == 0) return Value.initInteger(std.math.maxInt(i32));
    return Value.initInteger(@intCast(cap - @min(cap, sizeLocked(args[0]))));
}

/// The live elements as a cljw vector. Caller holds the lock.
fn snapshotLocked(rt: *Runtime, recv: Value) !Value {
    const v = vecOf(recv);
    const n = vector_mod.count(v);
    const head = headOf(recv);
    if (head >= n) return vector_mod.empty();
    return vector_mod.copyRange(rt, v, head, n);
}

/// `(.toArray q)` — a snapshot vector of the live elements, head first.
fn toArray(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".toArray", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    return snapshotLocked(rt, args[0]);
}

/// `(.remove q)` — remove and return the head, raising when empty (JVM-faithful;
/// `.poll` is the nil-returning form). `(.remove q x)` — drop the first element
/// equal to `x`, returning whether one was found.
fn remove(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange(".remove", args, 1, 2, loc);
    if (args.len == 1) {
        return (try tryPoll(rt, args[0])) orelse
            error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".remove", .expected = "a non-empty queue", .actual = "an empty queue" });
    }
    // Rebuild without the first match. O(n) — the JVM's is too, and this is a
    // coalescing path, not the hot enqueue/dequeue one.
    lock(args[0]);
    defer unlock(args[0]);
    const live = try snapshotLocked(rt, args[0]);
    const n = vector_mod.count(live);
    var out = vector_mod.empty();
    var found = false;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const e = vector_mod.nth(live, i);
        if (!found and try equal.valueEqual(rt, env, e, args[1])) {
            found = true;
            continue;
        }
        out = try vector_mod.conj(rt, out, e);
    }
    if (found) {
        setVec(args[0], out);
        setHead(args[0], 0);
    }
    return Value.initBoolean(found);
}

fn contains(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity(".contains", args, 2, loc);
    lock(args[0]);
    defer unlock(args[0]);
    const live = try snapshotLocked(rt, args[0]);
    const n = vector_mod.count(live);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (try equal.valueEqual(rt, env, vector_mod.nth(live, i), args[1]))
            return Value.initBoolean(true);
    }
    return Value.initBoolean(false);
}

fn clear(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".clear", args, 1, loc);
    lock(args[0]);
    defer unlock(args[0]);
    setVec(args[0], vector_mod.empty());
    setHead(args[0], 0);
    return Value.nil_val;
}

/// `(.drainTo q coll)` — cljw has no mutable target collection to drain INTO,
/// so this returns the drained elements as a vector and empties the queue. The
/// second argument is accepted and ignored for call-shape compatibility
/// (divergence AD-064).
fn drainTo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange(".drainTo", args, 1, 2, loc);
    lock(args[0]);
    defer unlock(args[0]);
    const live = try snapshotLocked(rt, args[0]);
    setVec(args[0], vector_mod.empty());
    setHead(args[0], 0);
    return live;
}

/// Mark the one backing Value each GC (the ArrayDeque pattern — no owned heap
/// memory, so no `host_finalise`).
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const v: Value = @enumFromInt(state[0]);
    if (v.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initQueue },
    .{ .name = "offer", .f = &offer },
    .{ .name = "put", .f = &put },
    .{ .name = "poll", .f = &poll },
    .{ .name = "take", .f = &take },
    .{ .name = "peek", .f = &peek },
    .{ .name = "element", .f = &peek },
    .{ .name = "size", .f = &size },
    .{ .name = "isEmpty", .f = &isEmpty },
    .{ .name = "remainingCapacity", .f = &remainingCapacity },
    .{ .name = "remove", .f = &remove },
    .{ .name = "contains", .f = &contains },
    .{ .name = "clear", .f = &clear },
    .{ .name = "toArray", .f = &toArray },
    .{ .name = "drainTo", .f = &drainTo },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    lbq_descriptor = td;
    td.host_trace = &traceState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.LinkedBlockingQueue",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.LinkedBlockingQueue",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
