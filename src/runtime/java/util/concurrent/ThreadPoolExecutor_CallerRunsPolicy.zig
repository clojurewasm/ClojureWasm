// SPDX-License-Identifier: EPL-2.0
//! Marker value for `ThreadPoolExecutor$CallerRunsPolicy`.
//!
//! Backend: impl-only
//! Impl deps: host_instance
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

pub const FQCN = "java.util.concurrent.ThreadPoolExecutor$CallerRunsPolicy";
var live_descriptor: ?*const type_descriptor.TypeDescriptor = null;

pub fn isCallerRunsPolicy(v: Value) bool {
    if (v.tag() != .host_instance) return false;
    const fqcn = host_instance.asHostInstance(v).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fqcn, FQCN);
}

pub fn make(rt: *Runtime) !Value {
    return host_instance.alloc(rt, live_descriptor orelse return error.NoVTable, .{ 0, 0, 0, 0 });
}

fn ctor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.concurrent.ThreadPoolExecutor$CallerRunsPolicy.", args, 0, loc);
    return make(rt);
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return;
    live_descriptor = td;
    try type_descriptor.appendMethodEntries(td, gpa, .{.{ "<init>", &ctor }});
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.ThreadPoolExecutor$CallerRunsPolicy",
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
