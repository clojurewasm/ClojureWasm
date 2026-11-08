// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalDateTime`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_date_time
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic date+time. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalDateTime VALUE (`runtime/time/local_date_time_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getYear /
//! getMonthValue / getDayOfMonth / getHour / getMinute / getSecond / getNano).
//! The civil↔epoch-day conversions are reused from the sibling
//! `runtime/time/instant.zig` (F-009 neutral home); `parse` / `from` /
//! `.format` go through the java.time.format engine
//! (`runtime/time/date_time_formatter_value.zig`).
//!
//! method_table is populated in `initLocalDateTime` (runtime) rather than at
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
const ldt_value = @import("../../time/local_date_time_value.zig");
const dtf_value = @import("../../time/date_time_formatter_value.zig");

const MS_PER_DAY: i64 = 86_400_000;

/// Build the `nano_of_day` from h/mi/s/n (all already validated in range).
fn nanoOfDay(h: i64, mi: i64, s: i64, n: i64) i64 {
    return ((h * 60 + mi) * 60 + s) * 1_000_000_000 + n;
}

/// `(java.time.LocalDateTime/of y m d h mi)` / `(… s)` / `(… s n)` — JVM
/// `LocalDateTime.of`. Arity 5-7: missing second / nano default to 0. All args
/// are integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalDateTime/of", args, 5, 7, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalDateTime/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    const y = args[0].asInteger();
    const m = args[1].asInteger();
    const d = args[2].asInteger();
    const h = args[3].asInteger();
    const mi = args[4].asInteger();
    const s = if (args.len >= 6) args[5].asInteger() else 0;
    const n = if (args.len >= 7) args[6].asInteger() else 0;
    return ldt_value.make(rt, instant.daysFromCivil(y, m, d), nanoOfDay(h, mi, s, n));
}

/// `(java.time.LocalDateTime/now)` — the current wall-clock date-time. cljw has
/// no zone DB, so this is UTC (clj's LocalDateTime.now() is local-zone). The
/// e2e does not assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDateTime/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    const epoch_day = @divFloor(ms, MS_PER_DAY);
    const nano_of_day = @mod(ms, MS_PER_DAY) * 1_000_000;
    return ldt_value.make(rt, epoch_day, nano_of_day);
}

/// `(java.time.LocalDateTime/parse s)` = `parse(s, DateTimeFormatter/ISO_LOCAL_DATE_TIME)`, and
/// `(java.time.LocalDateTime/parse s formatter)` (JVM `LocalDateTime.parse`). A failure is
/// the JVM DateTimeParseException.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalDateTime/parse", args, 1, 2, loc);
    if (args.len == 2) return dtf_value.parseTo(rt, .local_date_time, args[0], args[1], "java.time.LocalDateTime/parse", loc);
    return dtf_value.parseIso(rt, .local_date_time, args[0], "ISO_LOCAL_DATE_TIME", "java.time.LocalDateTime/parse", loc);
}

/// `(LocalDateTime/from temporal)` — JVM `LocalDateTime.from(TemporalAccessor)`.
fn from(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDateTime/from", args, 1, loc);
    return dtf_value.convert(rt, .local_date_time, args[0], loc);
}

/// `(.format x formatter)` — JVM `LocalDateTime.format(DateTimeFormatter)`.
fn formatFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("format", args, 2, loc);
    if (!dtf_value.isFormatter(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".format", .expected = "a DateTimeFormatter", .actual = dtf_value.classNameOf(args[1]) });
    return dtf_value.formatValue(rt, args[1], args[0], loc);
}

fn initLocalDateTime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalDateTime values point at it). Sentinel-guarded appends
    // keep both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
            .{ "from", &from },
            .{ "format", &formatFn },
        });
    }
    td.temporal_print = .iso_local_date_time;
    try ldt_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalDateTime",
    .descriptor = &descriptor,
    .init = &initLocalDateTime,
};

/// `LocalDateTime/{MIN,MAX}` (ADR-0174 D7b): LocalDate MIN/MAX combined with
/// LocalTime MIN/MAX, exactly the JVM composition.
const local_date_time_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MIN", .value = .{ .singleton = .time_local_date_time_min } },
    .{ .name = "MAX", .value = .{ .singleton = .time_local_date_time_max } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = ldt_value.FQCN, // "java.time.LocalDateTime" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &local_date_time_static_fields,
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_date_time,
};
