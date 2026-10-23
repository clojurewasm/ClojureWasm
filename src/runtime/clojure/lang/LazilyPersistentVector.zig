// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.LazilyPersistentVector` static helpers.
//!
//! Backend: impl-only
//! Impl deps: java_array, vector
//! Clojure peer: clojure.core/vec
//!
//! AD-030: the returned vector copies the array's slots, so a later `aset` on
//! the source array is not observable through it.

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const java_array = @import("../../collection/java_array.zig");
const vector_mod = @import("../../collection/vector.zig");

/// `(clojure.lang.LazilyPersistentVector/createOwning arr)` — a vector of the
/// array's elements, in order; `[]` for an empty array. A non-array raises.
fn createOwning(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("clojure.lang.LazilyPersistentVector/createOwning", args, 1, loc);
    if (!java_array.isArray(args[0]))
        return error_catalog.raise(.type_arg_invalid, loc, .{
            .fn_name = "clojure.lang.LazilyPersistentVector/createOwning",
            .expected = "a Java array",
            .actual = @tagName(args[0].tag()),
        });
    return java_array.toVector(rt, java_array.asArray(args[0]));
}

/// `(clojure.lang.LazilyPersistentVector/create coll)` — a vector of `coll`'s
/// elements. A Java array takes the `createOwning` path; any other seqable
/// routes through `clojure.core/vec`.
fn create(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.LazilyPersistentVector/create", args, 1, loc);
    if (java_array.isArray(args[0]))
        return java_array.toVector(rt, java_array.asArray(args[0]));
    const core = env.findNs("clojure.core") orelse return error.NoVTable;
    const vec_var = core.resolve("vec") orelse return error.NoVTable;
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, vec_var.deref(), args[0..1], loc);
}

fn initLazilyPersistentVector(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "createOwning", &createOwning },
        .{ "create", &create },
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
    .cljw_ns = "cljw.clojure.lang.LazilyPersistentVector",
    .descriptor = &descriptor,
    .init = &initLazilyPersistentVector,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.LazilyPersistentVector",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
