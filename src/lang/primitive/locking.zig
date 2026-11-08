// SPDX-License-Identifier: EPL-2.0
//! `locking` primitive — Clojure-ns surface for `(locking obj body...)`.
//!
//! The `locking` macro (lang/macro_transforms.zig) expands to
//! `(__locking obj (fn* [] body...))`; this primitive holds obj's heap-value
//! monitor (runtime/concurrency/object_monitor.zig — ADR-0009 lock_state bits,
//! NOT a JVM monitor) while it calls the body thunk on the calling thread,
//! releasing on normal OR error exit (defer). Reentrant.

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const object_monitor = @import("../../runtime/concurrency/object_monitor.zig");

/// The shared monitor every IMMEDIATE lock target uses. JVM `(locking 1 …)`
/// locks the interned Integer's monitor; cljw immediates carry no per-value
/// header, so they all share this one — mutual exclusion is preserved
/// (over-serialized across distinct immediates: a safe strengthening).
var immediate_monitor: @import("../../runtime/value/heap_header.zig").HeapHeader =
    @import("../../runtime/value/heap_header.zig").HeapHeader.init(.string);

/// `(__locking obj thunk)` — acquire obj's heap-value monitor (immediates
/// share one static monitor; nil raises, as clj's `monitor-enter` NPEs),
/// call `(thunk)`, release.
pub fn lockingFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("locking", args, 2, loc);
    if (args[0].isNil()) return error_catalog.raise(.locking_needs_object, loc, .{});
    const hdr = args[0].heapHeader() orelse &immediate_monitor;
    object_monitor.enter(hdr) catch
        return error_catalog.raise(.locking_nest_overflow, loc, .{ .cap = object_monitor.HELD_CAP });
    defer object_monitor.exit(hdr);
    const vtable = rt.vtable orelse return error.InternalError;
    return vtable.callFn(rt, env, args[1], &.{}, loc);
}

/// `(monitor-enter obj)` — acquire obj's monitor without a body thunk, the
/// half-primitive `locking` is built from. Returns nil; nil obj raises. The
/// caller owns the matching `monitor-exit` (clj has the same contract).
pub fn monitorEnter(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("monitor-enter", args, 1, loc);
    if (args[0].isNil()) return error_catalog.raise(.locking_needs_object, loc, .{});
    const hdr = args[0].heapHeader() orelse &immediate_monitor;
    object_monitor.enter(hdr) catch
        return error_catalog.raise(.locking_nest_overflow, loc, .{ .cap = object_monitor.HELD_CAP });
    return Value.nil_val;
}

/// `(monitor-exit obj)` — release a monitor taken by `monitor-enter`. Returns
/// nil; nil obj raises.
pub fn monitorExit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("monitor-exit", args, 1, loc);
    if (args[0].isNil()) return error_catalog.raise(.locking_needs_object, loc, .{});
    const hdr = args[0].heapHeader() orelse &immediate_monitor;
    object_monitor.exit(hdr);
    return Value.nil_val;
}

const Meta = env_mod.MetadataMap;

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
    meta: ?Meta = null,
};

const ENTRIES = [_]Entry{
    .{ .name = "__locking", .f = &lockingFn },
    // :doc / :arglists for these two are attached in clojure/core.clj
    // (alter-meta!), where `(:doc (meta v))` can see them.
    .{ .name = "monitor-enter", .f = &monitorEnter },
    .{ .name = "monitor-exit", .f = &monitorExit },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), it.meta);
    }
}
