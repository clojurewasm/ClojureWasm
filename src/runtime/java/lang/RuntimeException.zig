// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.RuntimeException` — the constructor
//! `(RuntimeException. msg)` (D-198 / clj-parity C5).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/ex-info (the cljw-native exception value)
//!
//! Same shape as `Exception.zig`; mints an `.ex_info` tagged
//! "RuntimeException" (no JVM class hierarchy, ADR-0059). `(catch Exception
//! …)` still catches it via the isSubclassOf hierarchy (RuntimeException <
//! Exception < Throwable).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const ex_info = @import("../../collection/ex_info.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;

fn runtimeExceptionCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = loc;
    return ex_info.allocExceptionFromArgs(rt, args, "RuntimeException");
}

fn initRuntimeException(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "<init>"),
        .method_val = Value.initBuiltinFn(&runtimeExceptionCtor),
    };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.RuntimeException",
    .descriptor = &descriptor,
    .init = &initRuntimeException,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "RuntimeException",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
