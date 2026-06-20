// SPDX-License-Identifier: EPL-2.0
//! `java.time.LocalDate` VALUE (D-462) — a timezone-agnostic calendar date.
//!
//! Mirrors the LocalDateTime model (`local_date_time_value.zig`): a no-slot
//! cljw-native `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag)
//! carrying ONE integer field — `epoch_day` (signed days since 1970-01-01,
//! via the Hinnant civil algorithm in `instant.zig`) — plus a per-Runtime
//! `.native` descriptor whose `temporal_print = .iso_local_date` makes the
//! printer emit the bare ISO local date string (NO `#tag`, no quotes — clj's
//! `(str ld)` form). The civil↔epoch-day conversions + the date format/parse
//! halves are reused from `instant.zig` (F-009 neutral home); the Java
//! `java.time.LocalDate` static surface (`runtime/java/time/LocalDate.zig`)
//! mints these from above.
//!
//! Distinct from the other temporal types by the per-Runtime descriptor
//! pointer (so `=` / print / `(class …)` discriminate) and by carrying the
//! instance methods getYear / getMonthValue / getDayOfMonth / plusDays.

const std = @import("std");
const value = @import("../value/value.zig");
const Value = value.Value;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const instant = @import("instant.zig");
const day_of_week_value = @import("day_of_week_value.zig");
const month_value = @import("month_value.zig");
const local_date_time_value = @import("local_date_time_value.zig");

/// `(.getYear d)` — the proleptic year (JVM `LocalDate.getYear`).
fn getYearFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getYear", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).y);
}

/// `(.getMonthValue d)` — the month 1..12 (JVM `LocalDate.getMonthValue`).
fn getMonthValueFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getMonthValue", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).m);
}

/// `(.getDayOfMonth d)` — the day-of-month 1..31 (JVM `LocalDate.getDayOfMonth`).
fn getDayOfMonthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getDayOfMonth", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).d);
}

/// `(.getDayOfWeek d)` — the DayOfWeek enum value (JVM `LocalDate.getDayOfWeek`).
/// epoch_day 0 (1970-01-01) is a Thursday = ISO 4; `@mod(epoch_day + 3, 7) + 1`
/// maps to 1=MONDAY .. 7=SUNDAY (negative-safe via `@mod`).
fn getDayOfWeekFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getDayOfWeek", args, 1, loc);
    return day_of_week_value.make(rt, @mod(epochDayOf(args[0]) + 3, 7) + 1);
}

/// `(.getMonth d)` — the Month enum value (JVM `LocalDate.getMonth`).
fn getMonthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getMonth", args, 1, loc);
    return month_value.make(rt, instant.civilFromDays(epochDayOf(args[0])).m);
}

/// `(.getDayOfYear d)` — the day-of-year 1..366 (JVM `LocalDate.getDayOfYear`).
fn getDayOfYearFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getDayOfYear", args, 1, loc);
    const ed = epochDayOf(args[0]);
    return Value.initInteger(ed - instant.daysFromCivil(instant.civilFromDays(ed).y, 1, 1) + 1);
}

/// `(.plusDays d n)` — the date `n` days later (JVM `LocalDate.plusDays`).
/// Mints a fresh LocalDate.
fn plusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochDayOf(args[0]) + args[1].asInteger());
}

/// `(.minusDays d n)` — the date `n` days earlier (JVM `LocalDate.minusDays`).
fn minusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochDayOf(args[0]) - args[1].asInteger());
}

/// `(.plusWeeks d n)` — the date `7*n` days later (JVM `LocalDate.plusWeeks`).
fn plusWeeksFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusWeeks", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusWeeks", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochDayOf(args[0]) + 7 * args[1].asInteger());
}

/// `(.minusWeeks d n)` — the date `7*n` days earlier (JVM `LocalDate.minusWeeks`).
fn minusWeeksFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusWeeks", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusWeeks", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochDayOf(args[0]) - 7 * args[1].asInteger());
}

/// Civil month-add with JVM day-clamping (the day clamps to the new month's
/// length, e.g. Jan-31 +1mo → Feb-28/29). Shared by plus/minusMonths.
fn addMonths(rt: *Runtime, self: Value, n: i64) !Value {
    return make(rt, instant.addMonthsToEpochDay(epochDayOf(self), n));
}

/// `(.plusMonths d n)` — civil month-add with day-clamping (JVM `LocalDate.plusMonths`).
fn plusMonthsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMonths", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMonths", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addMonths(rt, args[0], args[1].asInteger());
}

/// `(.minusMonths d n)` — civil month-subtract with day-clamping (JVM `LocalDate.minusMonths`).
fn minusMonthsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMonths", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMonths", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addMonths(rt, args[0], -args[1].asInteger());
}

/// Civil year-add with Feb-29 clamp (the day clamps to the target month's
/// length in the new year). Shared by plus/minusYears.
fn addYears(rt: *Runtime, self: Value, n: i64) !Value {
    return make(rt, instant.addYearsToEpochDay(epochDayOf(self), n));
}

/// `(.plusYears d n)` — civil year-add with Feb-29 clamp (JVM `LocalDate.plusYears`).
fn plusYearsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusYears", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusYears", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addYears(rt, args[0], args[1].asInteger());
}

/// `(.minusYears d n)` — civil year-subtract with Feb-29 clamp (JVM `LocalDate.minusYears`).
fn minusYearsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusYears", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusYears", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addYears(rt, args[0], -args[1].asInteger());
}

/// `(.isLeapYear d)` — true when the date's year is a leap year (JVM `LocalDate.isLeapYear`).
fn isLeapYearFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isLeapYear", args, 1, loc);
    return Value.initBoolean(instant.isLeap(instant.civilFromDays(epochDayOf(args[0])).y));
}

/// `(.lengthOfMonth d)` — the number of days in the date's month (JVM `LocalDate.lengthOfMonth`).
fn lengthOfMonthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("lengthOfMonth", args, 1, loc);
    const c = instant.civilFromDays(epochDayOf(args[0]));
    return Value.initInteger(instant.lengthOfMonth(c.y, c.m));
}

/// `(.isBefore a b)` — true when `a` is before `b` (JVM `LocalDate.isBefore`).
fn isBeforeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isBefore", args, 2, loc);
    if (!isLocalDate(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isBefore", .expected = "LocalDate", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochDayOf(args[0]) < epochDayOf(args[1]));
}

/// `(.isAfter a b)` — true when `a` is after `b` (JVM `LocalDate.isAfter`).
fn isAfterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isAfter", args, 2, loc);
    if (!isLocalDate(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isAfter", .expected = "LocalDate", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochDayOf(args[0]) > epochDayOf(args[1]));
}

/// `(.isEqual a b)` — true when `a` equals `b` (JVM `LocalDate.isEqual`).
fn isEqualFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isEqual", args, 2, loc);
    if (!isLocalDate(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isEqual", .expected = "LocalDate", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochDayOf(args[0]) == epochDayOf(args[1]));
}

/// `(.atStartOfDay d)` — the `LocalDateTime` at the start of this day (midnight),
/// the no-zone JVM `LocalDate.atStartOfDay()` overload. `nano_of_day = 0`.
fn atStartOfDayFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("atStartOfDay", args, 1, loc);
    return local_date_time_value.make(rt, epochDayOf(args[0]), 0);
}

/// `(.atTime d h m)` / `(.atTime d h m s)` / `(.atTime d h m s ns)` — the
/// `LocalDateTime` of this date at the given wall-clock time (JVM
/// `LocalDate.atTime` int overloads). h 0-23, m/s 0-59, ns 0-999999999; out of
/// range raises like the JVM `DateTimeException`.
fn atTimeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("atTime", args, 3, 5, loc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (args[i].tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "atTime", .expected = "integer", .actual = @tagName(args[i].tag()) });
    }
    const h = args[1].asInteger();
    const m = args[2].asInteger();
    const s = if (args.len > 3) args[3].asInteger() else 0;
    const ns = if (args.len > 4) args[4].asInteger() else 0;
    if (h < 0 or h > 23 or m < 0 or m > 59 or s < 0 or s > 59 or ns < 0 or ns > 999_999_999)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "atTime", .expected = "valid time fields (h 0-23, m/s 0-59, ns 0-999999999)", .actual = "out of range" });
    const nano_of_day: i64 = h * 3_600_000_000_000 + m * 60_000_000_000 + s * 1_000_000_000 + ns;
    return local_date_time_value.make(rt, epochDayOf(args[0]), nano_of_day);
}

/// The per-Runtime canonical LocalDate descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "LocalDate"` so
/// `(class …)` prints the simple name (AD-003 / no-JVM);
/// `temporal_print = .iso_local_date` drives the bare ISO local-date print form.
/// Carries the instance methods.
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.local_date_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "LocalDate",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .temporal_print = .iso_local_date,
    };
    const specs = .{
        .{ "getYear", &getYearFn },
        .{ "getMonthValue", &getMonthValueFn },
        .{ "getDayOfMonth", &getDayOfMonthFn },
        .{ "getDayOfWeek", &getDayOfWeekFn },
        .{ "getMonth", &getMonthFn },
        .{ "getDayOfYear", &getDayOfYearFn },
        .{ "plusDays", &plusDaysFn },
        .{ "minusDays", &minusDaysFn },
        .{ "plusWeeks", &plusWeeksFn },
        .{ "minusWeeks", &minusWeeksFn },
        .{ "plusMonths", &plusMonthsFn },
        .{ "minusMonths", &minusMonthsFn },
        .{ "plusYears", &plusYearsFn },
        .{ "minusYears", &minusYearsFn },
        .{ "isLeapYear", &isLeapYearFn },
        .{ "lengthOfMonth", &lengthOfMonthFn },
        .{ "isBefore", &isBeforeFn },
        .{ "isAfter", &isAfterFn },
        .{ "isEqual", &isEqualFn },
        .{ "atStartOfDay", &atStartOfDayFn },
        .{ "atTime", &atTimeFn },
    };
    const entries = try rt.gc.infra.alloc(TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try rt.gc.infra.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
    rt.local_date_descriptor = td;
    return td;
}

/// Build a LocalDate from `epoch_day` (signed days since 1970-01-01). One
/// typed_instance field.
pub fn make(rt: *Runtime, epoch_day: i64) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{Value.initInteger(epoch_day)});
}

/// True when `v` is a LocalDate (carries the per-Runtime descriptor).
pub fn isLocalDate(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.local_date_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
}

/// The `epoch_day` field. Caller must have checked `isLocalDate`.
pub fn epochDayOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.local_date_descriptor) |td| {
        for (td.method_table) |e| rt.gc.infra.free(e.method_name);
        if (td.method_table.len > 0) rt.gc.infra.free(td.method_table);
        rt.gc.infra.destroy(td);
        rt.local_date_descriptor = null;
    }
}

// --- tests ---

const testing = std.testing;

test "LocalDate value: make / isLocalDate / accessors + temporal_print set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const epoch_day = instant.daysFromCivil(2024, 3, 9);
    const d = try make(&rt, epoch_day);
    try testing.expect(d.tag() == .typed_instance);
    try testing.expect(isLocalDate(&rt, d));
    try testing.expectEqual(epoch_day, epochDayOf(d));
    try testing.expect(d.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_local_date);
    try testing.expect(!isLocalDate(&rt, Value.initInteger(5)));
}
