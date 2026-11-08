// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.format.DateTimeFormatter`.
//!
//! Backend: impl-only
//! Impl deps: date_time_format
//! Clojure peer: none
//!
//! Statics: `ofPattern` (a SMART formatter compiled from a pattern string; the
//! 2-arity Locale form is accepted, cljw's only locale being English) and the
//! STRICT `ISO_*` / `BASIC_ISO_DATE` constants. Instances are the
//! `.host_instance` formatters of `runtime/time/date_time_formatter_value.zig`,
//! which carry the instance methods (format / parse / withZone / getZone /
//! toString) on this same descriptor (ADR-0174 merge). The engine is
//! `runtime/time/date_time_format.zig`.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const string_collection = @import("../../../collection/string.zig");
const engine = @import("../../../time/date_time_format.zig");
const dtf_value = @import("../../../time/date_time_formatter_value.zig");

/// `(DateTimeFormatter/ofPattern "yyyy-MM-dd")` / `(… pattern locale)`.
fn ofPattern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.format.DateTimeFormatter/ofPattern", args, 1, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.format.DateTimeFormatter/ofPattern", .actual = @tagName(args[0].tag()) });
    var diag: engine.Diag = .{};
    const p = engine.compilePattern(rt.gc.infra, string_collection.asString(args[0]), &diag) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.DateTime => return dtf_value.raiseDiag(&diag, loc),
    };
    return dtf_value.wrapProgram(rt, p);
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.lookupMethod(null, "ofPattern") == null)
        try type_descriptor.appendMethodEntries(td, gpa, .{.{ "ofPattern", &ofPattern }});
    try dtf_value.ensureFormatterMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.format.DateTimeFormatter",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

/// The ISO constants, generated from the engine's table (index = arm payload).
const static_fields = build: {
    var arr: [engine.ISO_CONSTANTS.len]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, engine.ISO_CONSTANTS, 0..) |*sf, c, i| {
        sf.* = .{ .name = c.name, .value = .{ .date_time_formatter = @intCast(i) } };
    }
    break :build arr;
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = dtf_value.FORMATTER_FQCN, // the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
};
