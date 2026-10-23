// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalTime`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_time
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic time-of-day. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalTime VALUE (`runtime/time/local_time_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getHour /
//! getMinute / getSecond / getNano). `parse` / `from` / `.format` go through
//! the java.time.format engine (`runtime/time/date_time_formatter_value.zig`),
//! so a bad string is the JVM DateTimeParseException.
//!
//! method_table is populated in `initLocalTime` (runtime) rather than at
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
const lt_value = @import("../../time/local_time_value.zig");
const dtf_value = @import("../../time/date_time_formatter_value.zig");

const MS_PER_DAY: i64 = 86_400_000;
const NANO_PER_SECOND: i64 = 1_000_000_000;

/// Build the `nano_of_day` from h/mi/s/n (all already validated in range).
fn nanoOfDay(h: i64, mi: i64, s: i64, n: i64) i64 {
    return ((h * 60 + mi) * 60 + s) * NANO_PER_SECOND + n;
}

/// `(java.time.LocalTime/of h mi)` / `(… s)` / `(… s n)` — JVM `LocalTime.of`.
/// Arity 2-4: missing second / nano default to 0. All args are integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalTime/of", args, 2, 4, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalTime/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    const h = args[0].asInteger();
    const mi = args[1].asInteger();
    const s = if (args.len >= 3) args[2].asInteger() else 0;
    const n = if (args.len >= 4) args[3].asInteger() else 0;
    return lt_value.make(rt, nanoOfDay(h, mi, s, n));
}

/// `(java.time.LocalTime/now)` — the current wall-clock time-of-day. cljw has
/// no zone DB, so this is UTC (clj's LocalTime.now() is local-zone). The e2e
/// does not assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    return lt_value.make(rt, @mod(ms, MS_PER_DAY) * 1_000_000);
}

/// `(java.time.LocalTime/parse s)` = `parse(s, DateTimeFormatter/ISO_LOCAL_TIME)`, and
/// `(java.time.LocalTime/parse s formatter)` (JVM `LocalTime.parse`). A failure is
/// the JVM DateTimeParseException.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalTime/parse", args, 1, 2, loc);
    if (args.len == 2) return dtf_value.parseTo(rt, .local_time, args[0], args[1], "java.time.LocalTime/parse", loc);
    return dtf_value.parseIso(rt, .local_time, args[0], "ISO_LOCAL_TIME", "java.time.LocalTime/parse", loc);
}

/// `(LocalTime/from temporal)` — JVM `LocalTime.from(TemporalAccessor)`.
fn from(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/from", args, 1, loc);
    return dtf_value.convert(rt, .local_time, args[0], loc);
}

/// `(.format x formatter)` — JVM `LocalTime.format(DateTimeFormatter)`.
fn formatFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("format", args, 2, loc);
    if (!dtf_value.isFormatter(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".format", .expected = "a DateTimeFormatter", .actual = dtf_value.classNameOf(args[1]) });
    return dtf_value.formatValue(rt, args[1], args[0], loc);
}

const NANO_PER_DAY: i64 = 86_400_000_000_000;

/// `(java.time.LocalTime/ofSecondOfDay n)` — the time at second-of-day `n`
/// (0..86_399, JVM `LocalTime.ofSecondOfDay`); out of range raises
/// `.value_error` (JVM DateTimeException).
fn ofSecondOfDay(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/ofSecondOfDay", args, 1, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalTime/ofSecondOfDay", .expected = "integer", .actual = @tagName(args[0].tag()) });
    const s = args[0].asInteger();
    if (s < 0 or s >= 86_400)
        return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "java.time.LocalTime/ofSecondOfDay", .expected = "a second-of-day in 0..86399", .actual = "an out-of-range value" });
    return lt_value.make(rt, s * NANO_PER_SECOND);
}

/// `(java.time.LocalTime/ofNanoOfDay n)` — the time at nano-of-day `n`
/// (0..86_399_999_999_999, JVM `LocalTime.ofNanoOfDay`); out of range raises
/// `.value_error` (JVM DateTimeException).
fn ofNanoOfDay(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/ofNanoOfDay", args, 1, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalTime/ofNanoOfDay", .expected = "integer", .actual = @tagName(args[0].tag()) });
    const n = args[0].asInteger();
    if (n < 0 or n >= NANO_PER_DAY)
        return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = "java.time.LocalTime/ofNanoOfDay", .expected = "a nano-of-day in 0..86399999999999", .actual = "an out-of-range value" });
    return lt_value.make(rt, n);
}

fn initLocalTime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalTime values point at it). Sentinel-guarded appends keep
    // both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
            .{ "ofSecondOfDay", &ofSecondOfDay },
            .{ "ofNanoOfDay", &ofNanoOfDay },
            .{ "from", &from },
            .{ "format", &formatFn },
        });
    }
    td.temporal_print = .iso_local_time;
    try lt_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalTime",
    .descriptor = &descriptor,
    .init = &initLocalTime,
};

/// `LocalTime/{MIDNIGHT,MIN,NOON,MAX}` (ADR-0174 D7b). MIDNIGHT and MIN are
/// both 00:00 (JVM: MIN aliases MIDNIGHT's value), so they share one tag.
const local_time_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MIDNIGHT", .value = .{ .singleton = .time_local_time_midnight } },
    .{ .name = "MIN", .value = .{ .singleton = .time_local_time_midnight } },
    .{ .name = "NOON", .value = .{ .singleton = .time_local_time_noon } },
    .{ .name = "MAX", .value = .{ .singleton = .time_local_time_max } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = lt_value.FQCN, // "java.time.LocalTime" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &local_time_static_fields,
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_time,
};
