// SPDX-License-Identifier: EPL-2.0
//! java.io.PushbackReader constructor boundary. The wrapper and source share
//! one cursor; returning the source prevents competing GC owners of that cursor.
//!
//! Backend: impl-only
//! Impl deps: host_stream, text_io
//! Clojure peer: clojure.edn/read
const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_stream = @import("../../io/host_stream.zig");
const text_io = @import("../../io/text_io.zig");

fn construct(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.io.PushbackReader.", args, 1, loc);
    if (text_io.isTextReader(args[0]) or (try host_stream.remainingReader(rt, args[0])) != null) return args[0];
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "PushbackReader.", .expected = "a reader", .actual = @tagName(args[0].tag()) });
}

fn install(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.method_table.len != 0) return;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 1);
    entries[0] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, "<init>"), .method_val = Value.initBuiltinFn(&construct) };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.io.PushbackReader",
    .descriptor = &descriptor,
    .init = &install,
};
var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.io.PushbackReader",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
