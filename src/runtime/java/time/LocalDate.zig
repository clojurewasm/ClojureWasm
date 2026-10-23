// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalDate`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_date
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic calendar date. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalDate VALUE (`runtime/time/local_date_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getYear /
//! getMonthValue / getDayOfMonth / plusDays). The civil↔epoch-day conversions
//! are reused from the sibling `runtime/time/instant.zig` (F-009 neutral
//! home); `parse` / `from` / `.format` go through the java.time.format engine
//! (`runtime/time/date_time_formatter_value.zig`), so a bad string is the
//! JVM DateTimeParseException.
//!
//! method_table is populated in `initLocalDate` (runtime) rather than at
//! module scope because `Value.initBuiltinFn(&fn)` calls `@intFromPtr(&fn)`
//! which is not comptime-known on Mac targets in Zig 0.16.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const instant = @import("../../time/instant.zig");
const ld_value = @import("../../time/local_date_value.zig");
const dtf_value = @import("../../time/date_time_formatter_value.zig");

const MS_PER_DAY: i64 = 86_400_000;

/// `(java.time.LocalDate/of y m d)` — JVM `LocalDate.of`. All args integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/of", args, 3, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalDate/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    return ld_value.make(rt, instant.daysFromCivil(args[0].asInteger(), args[1].asInteger(), args[2].asInteger()));
}

/// `(java.time.LocalDate/now)` — the current wall-clock date. cljw has no zone
/// DB, so this is UTC (clj's LocalDate.now() is local-zone). The e2e does not
/// assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    return ld_value.make(rt, @divFloor(ms, MS_PER_DAY));
}

/// `(java.time.LocalDate/parse s)` = `parse(s, DateTimeFormatter/ISO_LOCAL_DATE)`, and
/// `(java.time.LocalDate/parse s formatter)` (JVM `LocalDate.parse`). A failure is
/// the JVM DateTimeParseException.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalDate/parse", args, 1, 2, loc);
    if (args.len == 2) return dtf_value.parseTo(rt, .local_date, args[0], args[1], "java.time.LocalDate/parse", loc);
    return dtf_value.parseIso(rt, .local_date, args[0], "ISO_LOCAL_DATE", "java.time.LocalDate/parse", loc);
}

/// `(LocalDate/from temporal)` — JVM `LocalDate.from(TemporalAccessor)`.
fn from(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/from", args, 1, loc);
    return dtf_value.convert(rt, .local_date, args[0], loc);
}

/// `(.format x formatter)` — JVM `LocalDate.format(DateTimeFormatter)`.
fn formatFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("format", args, 2, loc);
    if (!dtf_value.isFormatter(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".format", .expected = "a DateTimeFormatter", .actual = dtf_value.classNameOf(args[1]) });
    return dtf_value.formatValue(rt, args[1], args[0], loc);
}

/// `(java.time.LocalDate/ofEpochDay n)` — the date `n` days after 1970-01-01
/// (JVM `LocalDate.ofEpochDay`). The value model IS the epoch day, so this is
/// the identity constructor.
fn ofEpochDay(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/ofEpochDay", args, 1, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalDate/ofEpochDay", .expected = "integer", .actual = @tagName(args[0].tag()) });
    return ld_value.make(rt, args[0].asInteger());
}

fn initLocalDate(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalDate values point at it). Sentinel-guarded appends keep
    // both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
            .{ "ofEpochDay", &ofEpochDay },
            .{ "from", &from },
            .{ "format", &formatFn },
        });
    }
    td.temporal_print = .iso_local_date;
    try ld_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalDate",
    .descriptor = &descriptor,
    .init = &initLocalDate,
};

/// `LocalDate/{MIN,MAX,EPOCH}` (ADR-0174 D7b). MIN/MAX epoch days
/// (±year 999_999_999) fit the i48 immediate window (~±3.65e11 days).
const local_date_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MIN", .value = .{ .singleton = .time_local_date_min } },
    .{ .name = "MAX", .value = .{ .singleton = .time_local_date_max } },
    .{ .name = "EPOCH", .value = .{ .singleton = .time_local_date_epoch } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = ld_value.FQCN, // "java.time.LocalDate" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &local_date_static_fields,
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_date,
};
