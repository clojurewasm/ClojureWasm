// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.Semaphore` — a counting permit gate
//! over a `.host_instance` (ADR-0106): state[0] = permits (i64 bitcast, mutated
//! by CAS only), state[1] = the constructor's fairness flag.
//!
//! Backend: impl-only
//! Impl deps: host_instance, eval_budget, future, clock
//! Clojure peer: none
//!
//! Surface: `<init>` (permits [fair?]), `.acquire` ([n]), `.tryAcquire`
//! ([n] | [timeout unit] | [n timeout unit]), `.release` ([n]),
//! `.availablePermits`, `.drainPermits`.
//!
//! A blocking wait polls in slices through `eval_budget.budgetedSleep`, the
//! same wait `Thread/sleep` owns, so future-cancel and the eval budget cut it
//! short instead of pinning a worker for the whole timeout.
//!
//! Divergence AD-061: `fair?` is recorded and reported by `.isFair` but
//! acquisition always barges — there is no FIFO queue behind the permits.

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
const eval_budget = @import("../../../concurrency/eval_budget.zig");
const future = @import("../../../future.zig");
const clock = @import("../../../clock.zig");
const TimeUnit = @import("TimeUnit.zig");

/// The live rt.types descriptor (set in `initDescriptor`), embedded into every
/// instance so `<init>` and method dispatch share it.
var sem_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// Longest single wait slice; a shorter remaining budget shortens the last one.
const SLICE_NS: u64 = std.time.ns_per_ms;

fn permitsPtr(recv: Value) *u64 {
    return &@constCast(host_instance.asHostInstance(recv)).state[0];
}

fn permitsNow(recv: Value) i64 {
    return @bitCast(atomics.load(u64, permitsPtr(recv), .seq_cst));
}

/// CAS `n` permits out of the counter. False without blocking when fewer than
/// `n` are available.
fn takeNow(recv: Value, n: i64) bool {
    const ptr = permitsPtr(recv);
    while (true) {
        const cur_bits = atomics.load(u64, ptr, .seq_cst);
        const cur: i64 = @bitCast(cur_bits);
        if (cur < n) return false;
        const next: u64 = @bitCast(cur - n);
        if (atomics.cmpxchgWeak(u64, ptr, cur_bits, next, .seq_cst, .seq_cst) == null) return true;
    }
}

fn giveBack(recv: Value, n: i64) void {
    const ptr = permitsPtr(recv);
    while (true) {
        const cur_bits = atomics.load(u64, ptr, .seq_cst);
        const cur: i64 = @bitCast(cur_bits);
        const next: u64 = @bitCast(cur +| n);
        if (atomics.cmpxchgWeak(u64, ptr, cur_bits, next, .seq_cst, .seq_cst) == null) return;
    }
}

/// Poll for `n` permits until `deadline_ns` (null = no deadline). Returns false
/// on deadline; raises `future_cancel_abort` when the worker is cancelled.
fn takeWaiting(rt: *Runtime, recv: Value, n: i64, deadline_ns: ?i64) anyerror!bool {
    if (takeNow(recv, n)) return true;
    // Registered only once the caller actually parks, so `.getQueueLength`
    // counts waiters and not passers-by.
    const waiters = &@constCast(host_instance.asHostInstance(recv)).state[2];
    _ = atomics.rmw(u64, waiters, .Add, 1, .seq_cst);
    defer _ = atomics.rmw(u64, waiters, .Sub, 1, .seq_cst);
    while (true) {
        if (takeNow(recv, n)) return true;
        if (deadline_ns) |deadline| {
            const remaining = deadline - clock.nanoTime(rt.io);
            if (remaining <= 0) return false;
            const slice = @min(@as(u64, @intCast(remaining)), SLICE_NS);
            try eval_budget.budgetedSleep(rt.io, slice, future.currentCancelLatch());
        } else {
            try eval_budget.budgetedSleep(rt.io, SLICE_NS, future.currentCancelLatch());
        }
        if (future.cancelRequested()) return error_catalog.raise(.future_cancel_abort, .{}, .{});
    }
}

/// `(java.util.concurrent.Semaphore. n)` / `(… n fair?)`.
fn initSemaphore(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len != 1 and args.len != 2)
        return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.concurrent.Semaphore.", .expected = 1 });
    const permits = try error_catalog.expectInteger(args[0], "java.util.concurrent.Semaphore.", loc);
    const fair: u64 = if (args.len == 2 and args[1].isTruthy()) 1 else 0;
    const td = sem_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @bitCast(@as(i64, permits)), fair, 0, 0 });
}

/// The permit count an arity carries in `args[1]`, defaulting to 1.
fn permitArg(args: []const Value, name: []const u8, loc: SourceLocation) anyerror!i64 {
    if (args.len < 2) return 1;
    return @as(i64, try error_catalog.expectInteger(args[1], name, loc));
}

/// `(.acquire s)` / `(.acquire s n)` — block until acquired. Returns nil.
fn acquire(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange(".acquire", args, 1, 2, loc);
    _ = try takeWaiting(rt, args[0], try permitArg(args, ".acquire", loc), null);
    return Value.nil_val;
}

/// `(.tryAcquire s)` / `(.tryAcquire s n)` — immediate.
/// `(.tryAcquire s timeout unit)` / `(.tryAcquire s n timeout unit)` — timed.
fn tryAcquire(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange(".tryAcquire", args, 1, 4, loc);
    if (args.len <= 2)
        return Value.initBoolean(takeNow(args[0], try permitArg(args, ".tryAcquire", loc)));

    // Timed: the unit is last, the timeout immediately before it, and a 4-arg
    // call puts the permit count first — JVM's two timed overloads.
    const unit_idx = args.len - 1;
    const timeout = try error_catalog.expectInteger(args[unit_idx - 1], ".tryAcquire", loc);
    const n: i64 = if (args.len == 4) @as(i64, try error_catalog.expectInteger(args[1], ".tryAcquire", loc)) else 1;
    const timeout_ns = TimeUnit.nanosOf(args[unit_idx], @intCast(timeout)) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".tryAcquire", .expected = "a java.util.concurrent.TimeUnit", .actual = @tagName(args[unit_idx].tag()) });
    if (timeout_ns <= 0) return Value.initBoolean(takeNow(args[0], n));
    const deadline = clock.nanoTime(rt.io) +| timeout_ns;
    return Value.initBoolean(try takeWaiting(rt, args[0], n, deadline));
}

/// `(.release s)` / `(.release s n)` — returns nil (JVM release is void).
fn release(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArityRange(".release", args, 1, 2, loc);
    giveBack(args[0], try permitArg(args, ".release", loc));
    return Value.nil_val;
}

fn availablePermits(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".availablePermits", args, 1, loc);
    return Value.initInteger(permitsNow(args[0]));
}

/// `(.drainPermits s)` — take every available permit, returning the count.
fn drainPermits(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".drainPermits", args, 1, loc);
    const ptr = permitsPtr(args[0]);
    while (true) {
        const cur_bits = atomics.load(u64, ptr, .seq_cst);
        const cur: i64 = @bitCast(cur_bits);
        if (cur <= 0) return Value.initInteger(0);
        if (atomics.cmpxchgWeak(u64, ptr, cur_bits, @as(u64, @bitCast(@as(i64, 0))), .seq_cst, .seq_cst) == null)
            return Value.initInteger(cur);
    }
}

/// `(.getQueueLength s)` — callers currently parked in `acquire`/timed
/// `tryAcquire`. An estimate, as on the JVM.
fn getQueueLength(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getQueueLength", args, 1, loc);
    return Value.initInteger(@intCast(atomics.load(u64, &@constCast(host_instance.asHostInstance(args[0])).state[2], .seq_cst)));
}

fn hasQueuedThreads(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".hasQueuedThreads", args, 1, loc);
    return Value.initBoolean(atomics.load(u64, &@constCast(host_instance.asHostInstance(args[0])).state[2], .seq_cst) > 0);
}

/// `(.isFair s)` — the constructor flag. See AD-061: it does not change
/// acquisition order.
fn isFair(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isFair", args, 1, loc);
    return Value.initBoolean(host_instance.asHostInstance(args[0]).state[1] == 1);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initSemaphore },
    .{ .name = "acquire", .f = &acquire },
    .{ .name = "tryAcquire", .f = &tryAcquire },
    .{ .name = "release", .f = &release },
    .{ .name = "availablePermits", .f = &availablePermits },
    .{ .name = "drainPermits", .f = &drainPermits },
    .{ .name = "getQueueLength", .f = &getQueueLength },
    .{ .name = "hasQueuedThreads", .f = &hasQueuedThreads },
    .{ .name = "isFair", .f = &isFair },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    sem_descriptor = td;
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
    .cljw_ns = "cljw.java.util.concurrent.Semaphore",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.Semaphore",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
