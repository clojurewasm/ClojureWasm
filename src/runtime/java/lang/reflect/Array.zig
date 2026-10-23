// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.reflect.Array` static methods.
//!
//! Backend: impl-only
//! Impl deps: java_array
//! Clojure peer: clojure.core/object-array, aget, aset, alength
//!
//! AD-031: cljw arrays are Object[] (ADR-0105), so `newInstance` ignores the
//! component-type argument and always yields a nil-filled Object array.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const java_array = @import("../../../collection/java_array.zig");

/// `(java.lang.reflect.Array/newInstance component-type len)` — a nil-filled
/// array of `len` slots. A negative `len` raises.
fn newInstance(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.lang.reflect.Array/newInstance", args, 2, loc);
    const len = try error_catalog.expectInteger(args[1], "java.lang.reflect.Array/newInstance", loc);
    if (len < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "java.lang.reflect.Array/newInstance",
            .expected = "a non-negative length",
            .actual = "a negative length",
        });
    return java_array.make(rt, .object, @intCast(len));
}

/// `(java.lang.reflect.Array/getLength arr)` — the array's slot count.
fn getLength(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("java.lang.reflect.Array/getLength", args, 1, loc);
    if (!java_array.isArray(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "java.lang.reflect.Array/getLength",
            .expected = "a Java array",
            .actual = @tagName(args[0].tag()),
        });
    return Value.initInteger(@intCast(java_array.alength(args[0])));
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "newInstance", &newInstance },
        .{ "getLength", &getLength },
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
    .cljw_ns = "cljw.java.lang.reflect.Array",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.reflect.Array",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
