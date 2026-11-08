// SPDX-License-Identifier: EPL-2.0
//! java.io.StringReader constructor boundary. Buffer/cursor ownership belongs
//! to host_stream; EDN sees only the generic unread-reader capability.
//!
//! Backend: impl-only
//! Impl deps: host_stream
//! Clojure peer: clojure.edn/read
const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const string_collection = @import("../../collection/string.zig");
const host_stream = @import("../../io/host_stream.zig");

fn construct(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.io.StringReader.", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "StringReader.", .expected = "a string", .actual = @tagName(args[0].tag()) });
    return host_stream.mintReader(rt, string_collection.asString(args[0]));
}

fn install(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.method_table.len != 0) return;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "<init>"), .method_val = Value.initBuiltinFn(&construct) };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.io.StringReader",
    .descriptor = &descriptor,
    .init = &install,
};
var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.io.StringReader",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
