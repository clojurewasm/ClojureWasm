// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Thread` (ADR-0174 D6 — the minimal user
//! Thread lifecycle, user-authorized F-014 exception 2026-07-16).
//!
//! Backend: impl-only
//! Impl deps: thread
//! Clojure peer: none
//!
//! Statics: `sleep` / `currentThread` / `yield` / `onSpinWait` +
//! MIN/NORM/MAX_PRIORITY fields. Instances: `(Thread. f)` /
//! `(Thread. f name)` ctor + start / join(0|ms) / isAlive / getName /
//! setName / setDaemon / isDaemon on the neutral `runtime/thread.zig`
//! impl (future.zig's worker discipline; non-daemon join-at-exit
//! registry — JVM-faithful main wait). The interrupt family is
//! deliberately absent (flag-only interrupt cannot wake a sleeping
//! thread — a semantic lie); the D3 member diagnostic renders it.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const io_default = @import("../../concurrency/io_default.zig");
const future = @import("../../future.zig");
const host_instance = @import("../../host_instance.zig");
const string_mod = @import("../../collection/string.zig");
const thread_impl = @import("../../thread.zig");

/// Implements `(Thread/sleep millis)` — block the calling thread for `millis`
/// milliseconds, return nil. JVM reference: java.lang.Thread#sleep(long). A
/// non-positive `millis` is a no-op (JVM throws on negative — cljw treats <= 0
/// as "do not sleep", the only difference being the pathological negative case).
fn sleep(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Thread/sleep", args, 1, loc);
    const ms = try error_catalog.expectInteger(args[0], "Thread/sleep", loc);
    if (ms <= 0) return Value.nil_val;
    const total_ns = @as(u64, @intCast(ms)) * std.time.ns_per_ms;
    // Off a cancellable future worker (the common case — main thread, agent
    // drainer), one uninterrupted sleep. No behaviour change there.
    if (future.current_future == null) {
        io_default.sleep(total_ns);
        return Value.nil_val;
    }
    // On a future worker: D-442 / ADR-0153 sub-step 2a — poll the worker's cancel
    // flag in slices so `future-cancel` aborts the sleep promptly (releasing the
    // worker thread + GC pin) via the UNCATCHABLE `future_cancel_abort` signal,
    // which unwinds the thunk past its own `(catch Throwable …)`.
    const slice_ns: u64 = 20 * std.time.ns_per_ms;
    var remaining = total_ns;
    while (remaining > 0) {
        if (future.cancelRequested()) return error_catalog.raise(.future_cancel_abort, loc, .{});
        const this_slice = @min(remaining, slice_ns);
        io_default.sleep(this_slice);
        remaining -= this_slice;
    }
    // A cancel that landed during the final slice still aborts (so the worker
    // unwinds rather than running on into work whose result is discarded).
    if (future.cancelRequested()) return error_catalog.raise(.future_cancel_abort, loc, .{});
    return Value.nil_val;
}

/// Implements `(Thread/currentThread)` — the Thread object the calling OS
/// thread runs as: a started `(Thread. f)` worker returns ITS Thread
/// (threadlocal, set by the worker); main + non-Thread workers return the
/// process-lifetime "main" singleton (cached on `rt.thread_current`;
/// identity holds across calls, clj-faithful).
fn currentThread(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("Thread/currentThread", args, 0, loc);
    if (!thread_impl.current_thread_val.isNil()) return thread_impl.current_thread_val;
    if (!rt.thread_current.isNil()) return rt.thread_current;
    const td = rt.types.get(thread_impl.FQCN) orelse return error.InternalError;
    // The main singleton carries a real ThreadState (name "main", already
    // running) so getName/isAlive/host_trace treat it uniformly. A nil thunk
    // means nothing to trace; it is never started/joined.
    const v = try thread_impl.make(rt, env, Value.nil_val, "main", td);
    const st: *thread_impl.ThreadState = @ptrFromInt(host_instance.asHostInstance(v).state[0]);
    st.run_state = .running;
    try rt.gc.pin(v);
    rt.thread_current = v;
    return v;
}

fn expectThread(args: []const Value, fn_name: []const u8, loc: SourceLocation) anyerror!void {
    if (!thread_impl.isThread(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "Thread", .actual = @tagName(args[0].tag()) });
}

/// `(Thread. f)` / `(Thread. f name)` — an unstarted Thread over the 0-arg fn.
fn threadCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("Thread.", args, 1, 2, loc);
    switch (args[0].tag()) {
        .fn_val, .builtin_fn, .protocol_fn, .multi_fn => {},
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Thread.", .expected = "fn (Runnable)", .actual = @tagName(args[0].tag()) }),
    }
    var name: ?[]const u8 = null;
    if (args.len == 2) {
        if (args[1].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Thread.", .actual = @tagName(args[1].tag()) });
        name = string_mod.asString(args[1]);
    }
    const td = rt.types.get(thread_impl.FQCN) orelse return error.InternalError;
    return thread_impl.make(rt, env, args[0], name, td);
}

/// `(.start t)` — spawn the worker; second start raises (JVM-exact).
fn startFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".start", args, 1, loc);
    try expectThread(args, ".start", loc);
    return thread_impl.start(rt, args[0], loc);
}

/// `(.join t)` / `(.join t ms)` — wait for completion (ms: bounded wait).
fn joinFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArityRange(".join", args, 1, 2, loc);
    try expectThread(args, ".join", loc);
    if (args.len == 2) {
        const ms = try error_catalog.expectInteger(args[1], ".join", loc);
        thread_impl.join(args[0], ms);
    } else {
        thread_impl.join(args[0], null);
    }
    return Value.nil_val;
}

/// `(.isAlive t)` — started and not yet finished.
fn isAliveFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isAlive", args, 1, loc);
    try expectThread(args, ".isAlive", loc);
    return Value.initBoolean(thread_impl.runState(args[0]) == .running);
}

/// `(.getName t)` — the thread's real name ("main" for the main singleton;
/// "Thread-N" auto names; ctor/setName otherwise).
fn getName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".getName", args, 1, loc);
    try expectThread(args, ".getName", loc);
    return string_mod.alloc(rt, thread_impl.nameOf(args[0]));
}

fn setNameFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity(".setName", args, 2, loc);
    try expectThread(args, ".setName", loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = ".setName", .actual = @tagName(args[1].tag()) });
    try thread_impl.setName(rt, args[0], string_mod.asString(args[1]));
    return Value.nil_val;
}

/// `(.setDaemon t bool)` — before `.start` only (JVM-exact).
fn setDaemonFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".setDaemon", args, 2, loc);
    try expectThread(args, ".setDaemon", loc);
    if (args[1].tag() != .boolean)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".setDaemon", .expected = "boolean", .actual = @tagName(args[1].tag()) });
    return thread_impl.setDaemon(args[0], args[1] == Value.true_val, loc);
}

fn isDaemonFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".isDaemon", args, 1, loc);
    try expectThread(args, ".isDaemon", loc);
    return Value.initBoolean(thread_impl.isDaemon(args[0]));
}

/// `(Thread/yield)` — a scheduling hint (JVM-exact semantics: a hint).
fn yieldFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Thread/yield", args, 0, loc);
    std.Thread.yield() catch {
        // Unsupported platform → the hint is a no-op, matching the JVM spec
        // ("a hint to the scheduler ... free to ignore").
    };
    return Value.nil_val;
}

/// `(Thread/onSpinWait)` — the spin-loop hint (JVM Thread.onSpinWait).
fn onSpinWaitFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Thread/onSpinWait", args, 0, loc);
    std.atomic.spinLoopHint();
    return Value.nil_val;
}

const thread_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MIN_PRIORITY", .value = .{ .int = 1 } },
    .{ .name = "NORM_PRIORITY", .value = .{ .int = 5 } },
    .{ .name = "MAX_PRIORITY", .value = .{ .int = 10 } },
};

fn initThread(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    td.host_trace = &thread_impl.traceState;
    td.host_finalise = &thread_impl.finaliseState;
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "sleep", &sleep },
        .{ "currentThread", &currentThread },
        .{ "yield", &yieldFn },
        .{ "onSpinWait", &onSpinWaitFn },
        .{ "<init>", &threadCtor },
        .{ "start", &startFn },
        .{ "join", &joinFn },
        .{ "isAlive", &isAliveFn },
        .{ "getName", &getName },
        .{ "setName", &setNameFn },
        .{ "setDaemon", &setDaemonFn },
        .{ "isDaemon", &isDaemonFn },
    });
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Thread",
    .descriptor = &descriptor,
    .init = &initThread,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Thread",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &thread_static_fields,
    .parent = null,
    .meta = .nil_val,
};
