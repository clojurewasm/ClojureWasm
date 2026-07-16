// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Thread` static methods (Phase B).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! First slice: `(Thread/sleep millis)` blocks the calling thread for `millis`
//! milliseconds via `io_default.sleep` (`std.Thread.sleep` is gone in Zig 0.16
//! — sleep routes through the io). Thread objects / start / interrupt /
//! currentThread are later slices; cljw concurrency is `future`/`agent`/STM, not
//! raw Threads, so `Thread/sleep` (timing in tests / polling demos) is the
//! high-value static to land first.

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
const HeapHeader = @import("../../value/value.zig").HeapHeader;

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

/// Implements `(Thread/currentThread)` — returns the process-lifetime main-thread
/// host_instance singleton (cached on `rt.thread_current`; identity holds across
/// calls, clj-faithful). cljw runs user code on one thread; the object exists so
/// `(.getName (Thread/currentThread))` and thread-as-key idioms resolve.
fn currentThread(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Thread/currentThread", args, 0, loc);
    if (!rt.thread_current.isNil()) return rt.thread_current;
    const td = rt.types.get("java.lang.Thread") orelse return error.InternalError;
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ 0, 0, 0, 0 },
    };
    rt.thread_current = Value.encodeHeapPtr(.host_instance, inst);
    return rt.thread_current;
}

/// Implements `(.getName thread)` — the thread name. cljw's single user thread is
/// "main" (JVM's main-thread name), regardless of the receiver.
fn getName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Thread/getName", args, 1, loc);
    return string_mod.alloc(rt, "main");
}

fn initThread(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "sleep", &sleep },
        .{ "currentThread", &currentThread },
        .{ "getName", &getName },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
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
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
