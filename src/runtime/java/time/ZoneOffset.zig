// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.ZoneOffset` — a fixed offset from UTC.
//!
//! Backend: impl-only
//! Impl deps: zone_offset
//! Clojure peer: none
//!
//! The statics (of / ofHours / ofHoursMinutes / ofHoursMinutesSeconds /
//! ofTotalSeconds, UTC / MIN / MAX) mint the `.typed_instance` zone VALUE of
//! `runtime/time/zone_offset.zig`, whose descriptor (this one, ADR-0174 merge)
//! carries the instance methods getId / getTotalSeconds / normalized and the
//! `str` form (the id). Validation texts are the JVM DateTimeException ones.

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

fn intArg(v: Value, fn_name: []const u8, loc: SourceLocation) !i64 {
    if (v.tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "integer", .actual = @tagName(v.tag()) });
    return v.asInteger();
}

/// Mint from validated h/m/s; a validation failure raises its DateTimeException.
fn fromHms(rt: *Runtime, h: i64, m: i64, s: i64, loc: SourceLocation) !Value {
    var diag: zone_offset.Diag = .{};
    const secs = zone_offset.ofHoursMinutesSeconds(h, m, s, &diag) catch
        return error_catalog.raise(.date_time_value_invalid, loc, .{ .detail = diag.msg() });
    return zone_offset.make(rt, .{ .seconds = secs });
}

/// `(ZoneOffset/of "+02:00")` — JVM `ZoneOffset.of(String)`.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneOffset/of", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.ZoneOffset/of", .actual = @tagName(args[0].tag()) });
    const id = string_collection.asString(args[0]);
    var diag: zone_offset.Diag = .{};
    const secs = zone_offset.parseOffsetId(id, &diag) catch return zone_offset.raiseDiag(&diag, id, loc);
    return zone_offset.make(rt, .{ .seconds = secs });
}

fn ofHours(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneOffset/ofHours", args, 1, loc);
    return fromHms(rt, try intArg(args[0], "java.time.ZoneOffset/ofHours", loc), 0, 0, loc);
}

fn ofHoursMinutes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneOffset/ofHoursMinutes", args, 2, loc);
    const name = "java.time.ZoneOffset/ofHoursMinutes";
    return fromHms(rt, try intArg(args[0], name, loc), try intArg(args[1], name, loc), 0, loc);
}

fn ofHoursMinutesSeconds(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneOffset/ofHoursMinutesSeconds", args, 3, loc);
    const name = "java.time.ZoneOffset/ofHoursMinutesSeconds";
    return fromHms(rt, try intArg(args[0], name, loc), try intArg(args[1], name, loc), try intArg(args[2], name, loc), loc);
}

fn ofTotalSeconds(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.ZoneOffset/ofTotalSeconds", args, 1, loc);
    var diag: zone_offset.Diag = .{};
    const secs = zone_offset.ofTotalSeconds(try intArg(args[0], "java.time.ZoneOffset/ofTotalSeconds", loc), &diag) catch
        return error_catalog.raise(.date_time_value_invalid, loc, .{ .detail = diag.msg() });
    return zone_offset.make(rt, .{ .seconds = secs });
}

fn initZoneOffset(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.lookupMethod(null, "ofHours") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "ofHours", &ofHours },
            .{ "ofHoursMinutes", &ofHoursMinutes },
            .{ "ofHoursMinutesSeconds", &ofHoursMinutesSeconds },
            .{ "ofTotalSeconds", &ofTotalSeconds },
        });
    }
    try zone_offset.ensureOffsetMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.ZoneOffset",
    .descriptor = &descriptor,
    .init = &initZoneOffset,
};

const static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "UTC", .value = .{ .singleton = .time_zone_offset_utc } },
    .{ .name = "MIN", .value = .{ .singleton = .time_zone_offset_min } },
    .{ .name = "MAX", .value = .{ .singleton = .time_zone_offset_max } },
};

const supertypes = [_][]const u8{"java.time.ZoneId"};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = zone_offset.OFFSET_FQCN, // the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .host_supertypes = &supertypes,
    .parent = null,
    .meta = .nil_val,
};
