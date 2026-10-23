// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.ZoneId` — the abstract zone class: the statics
//! `of` and `systemDefault`. Instances are the ZoneOffset / ZoneRegion values
//! of `runtime/time/zone_offset.zig`, which list `java.time.ZoneId` as their
//! host supertype so `(instance? ZoneId z)` holds.
//!
//! Backend: impl-only
//! Impl deps: zone_offset
//! Clojure peer: none
//!
//! cljw has no time-zone database: `of` resolves offset ids and UTC / GMT / UT
//! (with an optional offset suffix) and refuses a region id such as
//! `Europe/Paris` with `zone_id_unknown`. `systemDefault` is the `UTC` region,
//! matching the UTC-based `LocalDate/now` and friends.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const string_collection = @import("../../collection/string.zig");
const zone_offset = @import("../../time/zone_offset.zig");

/// `(ZoneId/of "UTC")` — JVM `ZoneId.of(String)`.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneId/of", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.ZoneId/of", .actual = @tagName(args[0].tag()) });
    const id = string_collection.asString(args[0]);
    var diag: zone_offset.Diag = .{};
    const zone = zone_offset.parseZoneId(id, &diag) catch return zone_offset.raiseDiag(&diag, id, loc);
    return zone_offset.make(rt, zone);
}

/// `(ZoneId/systemDefault)` — the `UTC` region (cljw's clock is UTC).
fn systemDefault(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneId/systemDefault", args, 0, loc);
    return zone_offset.make(rt, .{ .seconds = 0, .prefix = .utc });
}

fn initZoneId(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    try type_descriptor.appendMethodEntries(td, gpa, .{
        .{ "of", &of },
        .{ "systemDefault", &systemDefault },
    });
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.ZoneId",
    .descriptor = &descriptor,
    .init = &initZoneId,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.time.ZoneId",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
