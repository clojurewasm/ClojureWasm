// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Runtime` — the `(Runtime/getRuntime)` singleton
//! and `(.availableProcessors r)` (D-425).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! `Runtime/getRuntime` returns the process-lifetime host_instance singleton
//! (cached on `rt.runtime_instance`; identity holds, clj-faithful).
//! `availableProcessors` (libraries size thread pools by it) → the host CPU
//! count via `std.Thread.getCpuCount`. cljw is no-JVM (ADR-0059); the rest of
//! the Runtime surface (exec / addShutdownHook) is out of scope —
//! `exit`/`halt` route through `System/exit`.
//!
//! The three memory readings answer from cljw's OWN mark-sweep accounting
//! (`rt.gc.stats`), never from a fabricated constant — a heap-pressure monitor
//! that reads a made-up denominator is worse than one that cannot read at all.
//! The mapping onto the JVM's vocabulary (divergence AD-063):
//!
//!   - `.totalMemory`: the cell heap cljw currently commits: the mapped GC
//!     pages (live cells, free slots, retained empty pages) plus live large
//!     cells (`GcHeap.committedBytes`). It grows with the heap and shrinks
//!     when a collect hands empty pages back to the OS, as the JVM's does.
//!   - `.freeMemory`: `totalMemory` minus the live cells: committed space
//!     the next allocations fill before the heap has to grow.
//!   - `.maxMemory` — `gc.heap_ceiling` (set by `CLJW_EVAL_MAX_HEAP_MB`,
//!     ADR-0125), or `Long/MAX_VALUE` when the heap is unmetered. An unmetered
//!     cljw genuinely has no ceiling, so a used/max pressure ratio reads ~0.
//!     That is the truth, not a stub.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const HeapHeader = @import("../../value/value.zig").HeapHeader;
const nan_box = @import("../../value/nan_box.zig");
const big_int = @import("../../numeric/big_int.zig");

/// Implements `(Runtime/getRuntime)` — the process-lifetime Runtime singleton
/// (cached on `rt.runtime_instance`; identity holds across calls).
fn getRuntime(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Runtime/getRuntime", args, 0, loc);
    if (!rt.runtime_instance.isNil()) return rt.runtime_instance;
    const td = rt.types.get("java.lang.Runtime") orelse return error.InternalError;
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ 0, 0, 0, 0 },
    };
    rt.runtime_instance = Value.encodeHeapPtr(.host_instance, inst);
    return rt.runtime_instance;
}

/// Implements `(.availableProcessors r)` — the host's logical CPU count. Falls
/// back to 1 if the OS query fails (a usable default, never an error).
fn availableProcessors(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Runtime/availableProcessors", args, 1, loc);
    const n = std.Thread.getCpuCount() catch 1;
    return Value.initInteger(@intCast(n));
}

/// Bytes the mark-sweep heap is currently holding for live objects.
fn liveBytes(rt: *const Runtime) usize {
    const s = rt.gc.stats;
    return s.bytes_allocated -| s.bytes_freed;
}

/// Saturating `usize` → a Clojure Long. A heap larger than `Long/MAX_VALUE`
/// pins rather than reporting a negative size.
///
/// Past i48 this MUST heap-box through `big_int` (the `.long` origin, so it
/// still prints and classes as Long): `Value.initInteger` silently converts an
/// out-of-i48 argument to an `f64`, which would hand `.maxMemory` back as
/// `9.223372036854776E18` — a double that fails `(= … Long/MAX_VALUE)` and
/// poisons any integer arithmetic a caller does with it.
fn asLong(rt: *Runtime, n: usize) !Value {
    const i = std.math.cast(i64, n) orelse std.math.maxInt(i64);
    if (i < nan_box.NB_I48_MIN or i > nan_box.NB_I48_MAX)
        return big_int.allocFromI64(rt, i, .long);
    return Value.initInteger(i);
}

/// `(.totalMemory r)` — see the module docstring for the JVM mapping (AD-063).
fn totalMemory(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Runtime/totalMemory", args, 1, loc);
    return asLong(rt, @max(liveBytes(rt), rt.gc.committedBytes()));
}

/// `(.freeMemory r)` — headroom inside `totalMemory` before the next collect.
fn freeMemory(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Runtime/freeMemory", args, 1, loc);
    const live = liveBytes(rt);
    return asLong(rt, @max(live, rt.gc.committedBytes()) - live);
}

/// `(.maxMemory r)` — the per-eval heap ceiling, or `Long/MAX_VALUE` when the
/// heap is unmetered (cljw then genuinely has no ceiling to report).
fn maxMemory(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Runtime/maxMemory", args, 1, loc);
    const ceiling = rt.gc.heap_ceiling orelse return big_int.allocFromI64(rt, std.math.maxInt(i64), .long);
    return asLong(rt, ceiling);
}

fn initRuntime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "getRuntime", &getRuntime },
        .{ "availableProcessors", &availableProcessors },
        .{ "totalMemory", &totalMemory },
        .{ "freeMemory", &freeMemory },
        .{ "maxMemory", &maxMemory },
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
    .cljw_ns = "cljw.java.lang.Runtime",
    .descriptor = &descriptor,
    .init = &initRuntime,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Runtime",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
