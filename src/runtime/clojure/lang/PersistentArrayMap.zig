// SPDX-License-Identifier: EPL-2.0
//! Host surface for `clojure.lang.PersistentArrayMap` static helpers.
//!
//! Backend: impl-only
//! Impl deps: java_array, map
//! Clojure peer: clojure.core/array-map

const std = @import("std");
const host_api = @import("../../java/_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const java_array = @import("../../collection/java_array.zig");
const map = @import("../../collection/map.zig");
const ex_info = @import("../../collection/ex_info.zig");
const dispatch = @import("../../dispatch.zig");
const print_mod = @import("../../print.zig");

fn expectPairArray(v: Value, fn_name: []const u8, loc: SourceLocation) ![]Value {
    if (!java_array.isKind(v, .object))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "an object array", .actual = @tagName(v.tag()) });
    const items = java_array.asArray(v).objects();
    if (items.len % 2 != 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "an even-length array", .actual = "an odd-length array" });
    return items;
}

/// `(clojure.lang.PersistentArrayMap/createWithCheck arr)` — a map from the
/// alternating key/value array, throwing IllegalArgumentException on a
/// duplicate key (JVM-faithful; `create` is the non-checking sibling).
fn createWithCheck(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("clojure.lang.PersistentArrayMap/createWithCheck", args, 1, loc);
    const items = try expectPairArray(args[0], "clojure.lang.PersistentArrayMap/createWithCheck", loc);
    var m = map.empty();
    var i: usize = 0;
    while (i < items.len) : (i += 2) {
        if (try map.contains(m, items[i])) {
            var aw: std.Io.Writer.Allocating = .init(rt.gpa);
            defer aw.deinit();
            aw.writer.writeAll("Duplicate key: ") catch return error.OutOfMemory;
            print_mod.printValue(null, &aw.writer, items[i]) catch return error.OutOfMemory;
            dispatch.last_thrown_exception = try ex_info.allocException(rt, aw.written(), "IllegalArgumentException");
            return error.ThrownValue;
        }
        m = try map.assoc(rt, m, items[i], items[i + 1]);
    }
    return m;
}

/// `(clojure.lang.PersistentArrayMap/create arr)` — the same build with no
/// duplicate check; a repeated key keeps its LAST value.
fn create(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("clojure.lang.PersistentArrayMap/create", args, 1, loc);
    const items = try expectPairArray(args[0], "clojure.lang.PersistentArrayMap/create", loc);
    var m = map.empty();
    var i: usize = 0;
    while (i < items.len) : (i += 2) m = try map.assoc(rt, m, items[i], items[i + 1]);
    return m;
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "createWithCheck", &createWithCheck },
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
    .cljw_ns = "cljw.clojure.lang.PersistentArrayMap",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "clojure.lang.PersistentArrayMap",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
