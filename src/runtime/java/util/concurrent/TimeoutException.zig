// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.concurrent.TimeoutException` — the constructor
//! `(TimeoutException.)` / `(TimeoutException. msg)`.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/ex-info (the cljw-native exception value)
//!
//! Same shape as `RuntimeException.zig`; mints an `.ex_info` tagged
//! "TimeoutException". `catch` already resolved this class before the surface
//! existed — `host_class.zig` carries both the FQCN mapping and the
//! `TimeoutException < Exception` edge — so the surface adds only the ability
//! to CONSTRUCT one. The executor tier's timed `.get` raises through the same
//! tag, which is why `(catch TimeoutException …)` sees it.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const ex_info = @import("../../../collection/ex_info.zig");
const SourceLocation = @import("../../../error/info.zig").SourceLocation;

fn timeoutExceptionCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    return ex_info.allocExceptionFromArgs(rt, args, "TimeoutException");
}

fn initTimeoutException(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "<init>"),
        .method_val = Value.initBuiltinFn(&timeoutExceptionCtor),
    };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.concurrent.TimeoutException",
    .descriptor = &descriptor,
    .init = &initTimeoutException,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.util.concurrent.TimeoutException",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
