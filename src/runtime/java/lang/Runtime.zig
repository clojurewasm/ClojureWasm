// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Runtime` — the `(Runtime/getRuntime)` singleton
//! and `(.availableProcessors r)` (D-425).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! `Runtime/getRuntime` returns the process-lifetime host_instance singleton
//! (cached on `rt.runtime_instance`; identity holds, clj-faithful). The only
//! wired instance method is `availableProcessors` (libraries size thread pools
//! by it) → the host CPU count via `std.Thread.getCpuCount`. cljw is no-JVM
//! (ADR-0059); the broader Runtime surface (exec / gc / freeMemory / addShutdown
//! Hook) is out of scope — `exit`/`halt` route through `System/exit`.

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

fn initRuntime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "getRuntime", &getRuntime },
        .{ "availableProcessors", &availableProcessors },
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
