// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.Date` (legacy time class kept around
//! for pre-Java-8 corpus compatibility).
//!
//! Backend: impl-only
//! Impl deps: date, instant
//! Clojure peer: clojure.core/inst-ms (reads the same epoch-ms field)
//!
//! `java.util.Date` is an epoch-ms wrapper. The VALUE is a `.typed_instance`
//! minted by `runtime/time/date.zig` (one epoch-ms field, `print_tag = "inst"`
//! → prints `#inst "…"`). This SURFACE adds the constructor `<init>`:
//! `(java.util.Date.)` = now, `(java.util.Date. ms)` = an epoch-ms Date. The
//! `.getTime` INSTANCE method lives on the per-Runtime Date descriptor (date.zig)
//! since the value carries that descriptor, not this surface one; `(inst-ms d)`
//! reads the same field. setTime / toInstant remain a follow-up (D-425).

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const date_impl = @import("../../time/date.zig");
const instant = @import("../../time/instant.zig");

/// `(java.util.Date.)` → a Date for the current epoch-ms (wall clock).
/// `(java.util.Date. ms)` → a Date for the given epoch-ms (long).
fn dateCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 0) return date_impl.make(rt, instant.nowEpochMillis(rt.io));
    if (args.len == 1) {
        if (args[0].tag() != .integer)
            return error_catalog.raise(.type_arg_not_integer, loc, .{ .fn_name = "java.util.Date.", .actual = @tagName(args[0].tag()) });
        return date_impl.make(rt, args[0].asInteger());
    }
    return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.util.Date.", .expected = 1 });
}

fn initDate(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the ctor AND the instance
    // methods (Date values point at it). Each side appends behind its own
    // sentinel so registration order (surface-first in production,
    // impl-first on a bare unit-test Runtime) does not matter.
    if (td.lookupMethod(null, "<init>") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "<init>", &dateCtor },
        });
    }
    td.print_tag = "inst"; // impl-first path sets it too; assign is idempotent
    try date_impl.ensureInstanceMethods(td, gpa);
}

const std = @import("std");

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.Date",
    .descriptor = &descriptor,
    .init = &initDate,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = date_impl.FQCN, // "java.util.Date" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .print_tag = "inst",
};
