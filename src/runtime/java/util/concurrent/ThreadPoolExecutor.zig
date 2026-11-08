// SPDX-License-Identifier: EPL-2.0
//! Java adapter for the bounded fixed-worker executor core.
//!
//! Backend: impl-only
//! Impl deps: thread_pool, Thread, LinkedBlockingQueue, TimeUnit, CallerRunsPolicy
//! Clojure peer: none

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const host_instance = @import("../../../host_instance.zig");
const thread_pool = @import("../../../concurrency/thread_pool.zig");
const thread_impl = @import("../../../thread.zig");
const dispatch = @import("../../../dispatch.zig");
const LinkedBlockingQueue = @import("LinkedBlockingQueue.zig");
const TimeUnit = @import("TimeUnit.zig");
const CallerRunsPolicy = @import("ThreadPoolExecutor_CallerRunsPolicy.zig");
const AbortPolicy = @import("ThreadPoolExecutor_AbortPolicy.zig");

pub const FQCN = "java.util.concurrent.ThreadPoolExecutor";
var pool_descriptor: ?*const type_descriptor.TypeDescriptor = null;

pub fn stateOf(v: Value) *thread_pool.PoolState {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(v).state[0])));
}

pub fn isPool(v: Value) bool {
    if (v.tag() != .host_instance) return false;
    const fqcn = host_instance.asHostInstance(v).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fqcn, FQCN);
}

fn expectPool(v: Value, name: []const u8, loc: SourceLocation) !void {
    if (!isPool(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = name, .expected = "ThreadPoolExecutor", .actual = @tagName(v.tag()) });
}

pub fn make(
    rt: *Runtime,
    env: *Env,
    worker_count: u32,
    queue: Value,
    thread_factory: Value,
    rejection_handler: Value,
    caller_runs: bool,
    scheduled: bool,
) !Value {
    const td = pool_descriptor orelse return error.NoVTable;
    const st = try rt.gc.infra.create(thread_pool.PoolState);
    st.* = .{
        .rt = rt,
        .env = env,
        .queue = .{ .value = queue, .offer = &LinkedBlockingQueue.tryOffer, .poll = &LinkedBlockingQueue.tryPoll },
        .thread_factory = thread_factory,
        .rejection_handler = rejection_handler,
        .caller_runs = caller_runs,
        .scheduled = scheduled,
    };
    const pool_value = host_instance.alloc(rt, td, .{ @intFromPtr(st), 0, 0, 0 }) catch |e| {
        rt.gc.infra.destroy(st);
        return e;
    };
    try thread_pool.prepareStart(st, pool_value);

    var i: u32 = 0;
    while (i < worker_count) : (i += 1) {
        const runnable = Value.initBuiltinFn(&workerRunnablePlaceholder);
        const thread_value = if (thread_factory.isNil()) blk: {
            const thread_td = rt.types.get(thread_impl.FQCN) orelse {
                thread_pool.workerStartFailed(st, false);
                return error.NoVTable;
            };
            break :blk thread_impl.make(rt, env, runnable, null, thread_td) catch |e| {
                thread_pool.workerStartFailed(st, false);
                return e;
            };
        } else blk: {
            var cs: dispatch.CallSite = .{};
            const made = dispatch.dispatchBareOrNull(rt, env, &cs, thread_factory, "newThread", &.{ thread_factory, runnable }, .{}) catch |e| {
                thread_pool.workerStartFailed(st, false);
                return e;
            } orelse {
                thread_pool.workerStartFailed(st, false);
                return error.NotThreadFactory;
            };
            break :blk made;
        };
        if (!thread_impl.isThread(thread_value)) {
            thread_pool.workerStartFailed(st, false);
            return error.NotThreadFactory;
        }
        thread_impl.attachNativeEntry(thread_value, &thread_pool.workerEntry, @ptrCast(st), .{}) catch |e| {
            thread_pool.workerStartFailed(st, false);
            return e;
        };
        thread_pool.workerWillStart(st);
        _ = thread_impl.start(rt, thread_value, .{}) catch |e| {
            thread_pool.workerStartFailed(st, true);
            return e;
        };
    }
    return pool_value;
}

/// ThreadFactory needs a Runnable-shaped callable to wrap in `(Thread. r)`.
/// `attachNativeEntry` replaces execution before start; reaching this function
/// would indicate a broken construction ordering.
fn workerRunnablePlaceholder(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("executor worker", args, 0, loc);
    return .nil_val;
}

/// Seven-argument JVM constructor.  The current executor core is deliberately
/// fixed-size, so `maximumPoolSize` is the worker count; hive-weave supplies
/// equal core/max values.  Keep-alive is irrelevant when workers are fixed but
/// its TimeUnit is validated instead of silently accepting a bogus object.
fn initPool(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("java.util.concurrent.ThreadPoolExecutor.", args, 7, loc);
    const core = try error_catalog.expectInteger(args[0], "java.util.concurrent.ThreadPoolExecutor.", loc);
    const maximum = try error_catalog.expectInteger(args[1], "java.util.concurrent.ThreadPoolExecutor.", loc);
    const keep_alive = try error_catalog.expectInteger(args[2], "java.util.concurrent.ThreadPoolExecutor.", loc);
    if (core <= 0 or maximum <= 0 or maximum < core)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.concurrent.ThreadPoolExecutor.", .expected = "0 < core <= maximum", .actual = "invalid pool size" });
    if (TimeUnit.nanosOf(args[3], keep_alive) == null)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.concurrent.ThreadPoolExecutor.", .expected = "a java.util.concurrent.TimeUnit", .actual = @tagName(args[3].tag()) });
    if (!LinkedBlockingQueue.isQueue(args[4]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.concurrent.ThreadPoolExecutor.", .expected = "LinkedBlockingQueue", .actual = @tagName(args[4].tag()) });
    const caller_runs = CallerRunsPolicy.isCallerRunsPolicy(args[6]);
    if (!caller_runs and !AbortPolicy.isAbortPolicy(args[6]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.util.concurrent.ThreadPoolExecutor.", .expected = "a RejectedExecutionHandler", .actual = @tagName(args[6].tag()) });
    return make(rt, env, @intCast(maximum), args[4], args[5], args[6], caller_runs, false);
}

fn submit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".submit", args, 2, loc);
    try expectPool(args[0], ".submit", loc);
    return thread_pool.submit(stateOf(args[0]), args[1], loc);
}

fn scheduleAtFixedRate(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".scheduleAtFixedRate", args, 5, loc);
    try expectPool(args[0], ".scheduleAtFixedRate", loc);
    const initial = try error_catalog.expectInteger(args[2], ".scheduleAtFixedRate", loc);
    const period = try error_catalog.expectInteger(args[3], ".scheduleAtFixedRate", loc);
    const delay_ns = TimeUnit.nanosOf(args[4], initial) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".scheduleAtFixedRate", .expected = "TimeUnit", .actual = @tagName(args[4].tag()) });
    const period_ns = TimeUnit.nanosOf(args[4], period) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".scheduleAtFixedRate", .expected = "TimeUnit", .actual = @tagName(args[4].tag()) });
    return thread_pool.scheduleAtFixedRate(stateOf(args[0]), args[1], delay_ns, period_ns, loc);
}

fn shutdown(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".shutdown", args, 1, loc);
    try expectPool(args[0], ".shutdown", loc);
    thread_pool.shutdown(stateOf(args[0]));
    return .nil_val;
}

fn shutdownNow(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".shutdownNow", args, 1, loc);
    try expectPool(args[0], ".shutdownNow", loc);
    return thread_pool.shutdownNow(stateOf(args[0]));
}

fn awaitTermination(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".awaitTermination", args, 3, loc);
    try expectPool(args[0], ".awaitTermination", loc);
    const timeout = try error_catalog.expectInteger(args[1], ".awaitTermination", loc);
    const timeout_ns = TimeUnit.nanosOf(args[2], timeout) orelse
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".awaitTermination", .expected = "a java.util.concurrent.TimeUnit", .actual = @tagName(args[2].tag()) });
    _ = rt;
    return Value.initBoolean(try thread_pool.awaitTermination(stateOf(args[0]), timeout_ns));
}

fn isShutdownFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isShutdown", args, 1, loc);
    try expectPool(args[0], ".isShutdown", loc);
    return Value.initBoolean(thread_pool.isShutdown(stateOf(args[0])));
}

fn isTerminatedFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isTerminated", args, 1, loc);
    try expectPool(args[0], ".isTerminated", loc);
    return Value.initBoolean(thread_pool.isTerminated(stateOf(args[0])));
}

fn getQueue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getQueue", args, 1, loc);
    try expectPool(args[0], ".getQueue", loc);
    return stateOf(args[0]).queue.value;
}

const METHODS = .{
    .{ "<init>", &initPool },
    .{ "submit", &submit },
    .{ "scheduleAtFixedRate", &scheduleAtFixedRate },
    .{ "shutdown", &shutdown },
    .{ "shutdownNow", &shutdownNow },
    .{ "awaitTermination", &awaitTermination },
    .{ "isShutdown", &isShutdownFn },
    .{ "isTerminated", &isTerminatedFn },
    .{ "getQueue", &getQueue },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return;
    pool_descriptor = td;
    td.host_trace = &thread_pool.traceState;
    td.host_finalise = &thread_pool.finaliseState;
    try type_descriptor.appendMethodEntries(td, gpa, METHODS);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.ThreadPoolExecutor",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = FQCN,
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
