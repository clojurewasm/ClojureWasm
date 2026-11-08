// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.PersistentList` static helpers.
//!
//! Backend: impl-only
//! Impl deps: —
//! Clojure peer: clojure.core/list, clojure.core/apply

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");

/// `(clojure.lang.PersistentList/create coll)` — a list of `coll`'s elements in
/// order; `()` when empty. Routes through `clojure.core/apply` + `list`, so any
/// seqable is accepted.
fn create(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("clojure.lang.PersistentList/create", args, 1, loc);
    const core = env.findNs("clojure.core") orelse return error.NoVTable;
    const apply_var = core.resolve("apply") orelse return error.NoVTable;
    const list_var = core.resolve("list") orelse return error.NoVTable;
    const vt = rt.vtable orelse return error.NoVTable;
    return vt.callFn(rt, env, apply_var.deref(), &.{ list_var.deref(), args[0] }, loc);
}

fn initPersistentList(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
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
    .cljw_ns = "cljw.clojure.lang.PersistentList",
    .descriptor = &descriptor,
    .init = &initPersistentList,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.PersistentList",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
