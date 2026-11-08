// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.format.DateTimeFormatterBuilder` — the fluent
//! builder `(DateTimeFormatterBuilder.)`; each `append…` / `optional…` /
//! `parse…` call mutates the builder and returns it, `toFormatter` freezes a
//! SMART `DateTimeFormatter`.
//!
//! Backend: impl-only
//! Impl deps: date_time_format
//! Clojure peer: none
//!
//! The instance methods live in `runtime/time/date_time_formatter_value.zig`
//! (registered onto this descriptor by `init`); this file owns `<init>`.

const std = @import("std");
const host_api = @import("../../_host_api.zig");
const type_descriptor = @import("../../../type_descriptor.zig");
const Value = @import("../../../value/value.zig").Value;
const Runtime = @import("../../../runtime.zig").Runtime;
const Env = @import("../../../env.zig").Env;
const SourceLocation = @import("../../../error/info.zig").SourceLocation;
const error_catalog = @import("../../../error/catalog.zig");
const dtf_value = @import("../../../time/date_time_formatter_value.zig");

/// `(DateTimeFormatterBuilder.)` — an empty builder.
fn initBuilder(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("DateTimeFormatterBuilder", args, 0, loc);
    return dtf_value.newBuilder(rt);
}

fn initDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.lookupMethod(null, "<init>") == null)
        try type_descriptor.appendMethodEntries(td, gpa, .{.{ "<init>", &initBuilder }});
    try dtf_value.ensureBuilderMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.format.DateTimeFormatterBuilder",
    .descriptor = &descriptor,
    .init = &initDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = dtf_value.BUILDER_FQCN, // the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
