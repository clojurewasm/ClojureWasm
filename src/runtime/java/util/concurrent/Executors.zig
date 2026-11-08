// SPDX-License-Identifier: EPL-2.0
//! Static factories for fixed and single-thread executors.
//!
//! Backend: impl-only
//! Impl deps: LinkedBlockingQueue, ThreadPoolExecutor
//! Clojure peer: none

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const LinkedBlockingQueue = @import("LinkedBlockingQueue.zig");
const ThreadPoolExecutor = @import("ThreadPoolExecutor.zig");

fn fixed(rt: *Runtime, env: *Env, n: i64, factory: Value, loc: SourceLocation) !Value {
    if (n <= 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Executors/newFixedThreadPool", .expected = "a positive thread count", .actual = "a non-positive thread count" });
    const queue = try LinkedBlockingQueue.make(rt, 0);
    return ThreadPoolExecutor.make(rt, env, @intCast(n), queue, factory, .nil_val, true, false);
}

fn newFixedThreadPool(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("Executors/newFixedThreadPool", args, 1, 2, loc);
    const n = try error_catalog.expectInteger(args[0], "Executors/newFixedThreadPool", loc);
    return fixed(rt, env, n, if (args.len == 2) args[1] else .nil_val, loc);
}

fn newSingleThreadExecutor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("Executors/newSingleThreadExecutor", args, 0, 1, loc);
    return fixed(rt, env, 1, if (args.len == 1) args[0] else .nil_val, loc);
}

fn newSingleThreadScheduledExecutor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("Executors/newSingleThreadScheduledExecutor", args, 0, 1, loc);
    const queue = try LinkedBlockingQueue.make(rt, 0);
    return ThreadPoolExecutor.make(rt, env, 1, queue, if (args.len == 1) args[0] else .nil_val, .nil_val, true, true);
}

const METHODS = .{
    .{ "newSingleThreadScheduledExecutor", &newSingleThreadScheduledExecutor },
    .{ "newFixedThreadPool", &newFixedThreadPool },
    .{ "newSingleThreadExecutor", &newSingleThreadExecutor },
};

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return;
    try type_descriptor.appendMethodEntries(td, gpa, METHODS);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.Executors",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.Executors",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &.{},
    .parent = null,
    .meta = .nil_val,
};
