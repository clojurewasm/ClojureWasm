// SPDX-License-Identifier: EPL-2.0
//! `java.time.LocalDateTime` VALUE (D-462) — a timezone-agnostic date+time.
//!
//! Mirrors the Instant/Duration model (`instant_value.zig` /
//! `duration_value.zig`): a no-slot cljw-native `.typed_instance` (F-004
//! layout UNCHANGED, no NaN-box tag) carrying TWO integer fields —
//! `epoch_day` (signed days since 1970-01-01, via the Hinnant civil algorithm
//! in `instant.zig`) + `nano_of_day` (in [0, 86_400_000_000_000)) — plus a
//! per-Runtime `.native` descriptor whose `temporal_print = .iso_local_date_time`
//! makes the printer emit the bare ISO local date-time string (NO `#tag`, no
//! quotes — clj's `(str ldt)` form). The civil↔epoch-day conversions are
//! reused from `instant.zig` (F-009 neutral home); the Java
//! `java.time.LocalDateTime` static surface (`runtime/java/time/LocalDateTime.zig`)
//! mints these from above.
//!
//! Distinct from Instant/Duration/Date/Timestamp by the per-Runtime descriptor
//! pointer (so `=` / print / `(class …)` discriminate) and by carrying the
//! instance methods getYear / getMonthValue / getDayOfMonth / getHour /
//! getMinute / getSecond / getNano.

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
const local_date_value = @import("local_date_value.zig");
const local_time_value = @import("local_time_value.zig");
const duration_value = @import("duration_value.zig");
const host_instance = @import("../host_instance.zig");
const host_enum = @import("../host_enum.zig");
const big_int = @import("../numeric/big_int.zig");
const nb = @import("../value/nan_box.zig");

/// `(.getYear d)` — the proleptic year (JVM `LocalDateTime.getYear`).
fn getYearFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getYear", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).y);
}

/// `(.getMonthValue d)` — the month 1..12 (JVM `LocalDateTime.getMonthValue`).
fn getMonthValueFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getMonthValue", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).m);
}

/// `(.getDayOfMonth d)` — the day-of-month 1..31 (JVM `LocalDateTime.getDayOfMonth`).
fn getDayOfMonthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getDayOfMonth", args, 1, loc);
    return Value.initInteger(instant.civilFromDays(epochDayOf(args[0])).d);
}

/// `(.getDayOfWeek d)` — the DayOfWeek enum value (JVM `LocalDateTime.getDayOfWeek`).
/// Uses the date part (epoch_day); epoch_day 0 (1970-01-01) is a Thursday = ISO 4,
/// so `@mod(epoch_day + 3, 7) + 1` maps to 1=MONDAY .. 7=SUNDAY.
fn getDayOfWeekFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getDayOfWeek", args, 1, loc);
    // ordinal = ISO value - 1; ISO value = @mod(epoch_day+3,7)+1 (epoch day 0 = Thu).
    return host_enum.singleton(rt, .day_of_week, @intCast(@mod(epochDayOf(args[0]) + 3, 7)));
}

/// `(.getMonth d)` — the Month enum value (JVM `LocalDateTime.getMonth`).
fn getMonthFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getMonth", args, 1, loc);
    // ordinal = month value (1..12) - 1.
    return host_enum.singleton(rt, .month, @intCast(instant.civilFromDays(epochDayOf(args[0])).m - 1));
}

/// `(.getDayOfYear d)` — the day-of-year 1..366 (JVM `LocalDateTime.getDayOfYear`).
fn getDayOfYearFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getDayOfYear", args, 1, loc);
    const ed = epochDayOf(args[0]);
    return Value.initInteger(ed - instant.daysFromCivil(instant.civilFromDays(ed).y, 1, 1) + 1);
}

/// `(.getHour d)` — the hour-of-day 0..23 (JVM `LocalDateTime.getHour`).
fn getHourFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getHour", args, 1, loc);
    return Value.initInteger(@divTrunc(nanoOfDayOf(args[0]), 3_600_000_000_000));
}

/// `(.getMinute d)` — the minute-of-hour 0..59 (JVM `LocalDateTime.getMinute`).
fn getMinuteFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getMinute", args, 1, loc);
    return Value.initInteger(@rem(@divTrunc(nanoOfDayOf(args[0]), 60_000_000_000), 60));
}

/// `(.getSecond d)` — the second-of-minute 0..59 (JVM `LocalDateTime.getSecond`).
fn getSecondFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getSecond", args, 1, loc);
    return Value.initInteger(@rem(@divTrunc(nanoOfDayOf(args[0]), 1_000_000_000), 60));
}

/// `(.getNano d)` — the nanosecond-of-second 0..999_999_999 (JVM
/// `LocalDateTime.getNano`).
fn getNanoFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getNano", args, 1, loc);
    return Value.initInteger(@rem(nanoOfDayOf(args[0]), 1_000_000_000));
}

/// `(.toLocalDate d)` — the date half as a LocalDate (JVM
/// `LocalDateTime.toLocalDate`).
fn toLocalDateFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toLocalDate", args, 1, loc);
    return local_date_value.make(rt, epochDayOf(args[0]));
}

/// `(.toLocalTime d)` — the time half as a LocalTime (JVM
/// `LocalDateTime.toLocalTime`).
fn toLocalTimeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toLocalTime", args, 1, loc);
    return local_time_value.make(rt, nanoOfDayOf(args[0]));
}

/// `(.isBefore a b)` — true when `a` precedes `b` (JVM `LocalDateTime.isBefore`).
/// Compares lexicographically by (epoch-day, then nano-of-day).
fn isBeforeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isBefore", args, 2, loc);
    if (!isLocalDateTime(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isBefore", .expected = "LocalDateTime", .actual = @tagName(args[1].tag()) });
    const a_day = epochDayOf(args[0]);
    const b_day = epochDayOf(args[1]);
    return Value.initBoolean(a_day < b_day or (a_day == b_day and nanoOfDayOf(args[0]) < nanoOfDayOf(args[1])));
}

/// `(.isAfter a b)` — true when `a` follows `b` (JVM `LocalDateTime.isAfter`).
fn isAfterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isAfter", args, 2, loc);
    if (!isLocalDateTime(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isAfter", .expected = "LocalDateTime", .actual = @tagName(args[1].tag()) });
    const a_day = epochDayOf(args[0]);
    const b_day = epochDayOf(args[1]);
    return Value.initBoolean(a_day > b_day or (a_day == b_day and nanoOfDayOf(args[0]) > nanoOfDayOf(args[1])));
}

/// `(.isEqual a b)` — true when `a` equals `b` (JVM `LocalDateTime.isEqual`).
fn isEqualFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isEqual", args, 2, loc);
    if (!isLocalDateTime(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isEqual", .expected = "LocalDateTime", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(epochDayOf(args[0]) == epochDayOf(args[1]) and nanoOfDayOf(args[0]) == nanoOfDayOf(args[1]));
}

const DAY_NS: i64 = 86_400_000_000_000;
const HOUR_NS: i64 = 3_600_000_000_000;
const MIN_NS: i64 = 60_000_000_000;
const SEC_NS: i64 = 1_000_000_000;

/// An integer count Value: a fixnum when it fits the i48 window, else a promoted
/// Long. `.until` in NANOS/MICROS/MILLIS can exceed i48 over a multi-day span.
fn makeLong(rt: *Runtime, v: i64) !Value {
    if (v >= nb.NB_I48_MIN and v <= nb.NB_I48_MAX) return Value.initInteger(v);
    return big_int.allocFromI64(rt, v, .long);
}

/// `(.until d1 d2 unit)` — whole count of ChronoUnit `unit` from d1 to d2 (JVM
/// `LocalDateTime.until`). Date units (DAYS..MILLENNIA) adjust the end date ±1 by
/// the time-of-day comparison then reuse `instant.dateUntil`; time units
/// (NANOS..HALF_DAYS) use the JVM piecewise day-split (so SECONDS+ never overflow
/// across realistic spans; a NANOS span beyond ±292 years overflows → raise, as
/// JVM's Math.multiplyExact throws). ERAS/FOREVER raise.
fn untilFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("until", args, 3, loc);
    if (!isLocalDateTime(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "LocalDateTime", .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .host_instance)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a ChronoUnit", .actual = @tagName(args[2].tag()) });
    const ord: u8 = @intCast(host_instance.asHostInstance(args[2]).state[0]);
    const ed1 = epochDayOf(args[0]);
    const ed2 = epochDayOf(args[1]);
    const nod1 = nanoOfDayOf(args[0]);
    const nod2 = nanoOfDayOf(args[1]);

    if (ord >= 7 and ord <= 13) { // date-based: adjust the end date by the time-of-day
        var ed2_adj = ed2;
        if (ed2 > ed1 and nod2 < nod1) {
            ed2_adj -= 1;
        } else if (ed2 < ed1 and nod2 > nod1) {
            ed2_adj += 1;
        }
        return makeLong(rt, instant.dateUntil(ed1, ed2_adj, ord).?);
    }
    if (ord > 6) // ERAS (14) / FOREVER (15)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a supported ChronoUnit", .actual = host_enum.name(.chrono_unit, ord) });

    // Time-based (0-6): JVM piecewise day-split to keep SECONDS+ in range.
    const per_day: i64 = switch (ord) {
        0 => DAY_NS, // NANOS
        1 => 86_400_000_000, // MICROS
        2 => 86_400_000, // MILLIS
        3 => 86_400, // SECONDS
        4 => 1_440, // MINUTES
        5 => 24, // HOURS
        6 => 2, // HALF_DAYS
        else => unreachable,
    };
    const per_unit: i64 = switch (ord) {
        0 => 1,
        1 => 1_000,
        2 => 1_000_000,
        3 => SEC_NS,
        4 => MIN_NS,
        5 => HOUR_NS,
        6 => HOUR_NS * 12,
        else => unreachable,
    };
    var days = ed2 - ed1;
    var time_part = nod2 - nod1;
    if (days == 0) return makeLong(rt, @divTrunc(time_part, per_unit));
    if (days > 0) {
        days -= 1;
        time_part += DAY_NS;
    } else {
        days += 1;
        time_part -= DAY_NS;
    }
    const amount = @mulWithOverflow(days, per_day);
    if (amount[1] != 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a span representable in the requested unit", .actual = "a span too large for the requested unit" });
    const total = @addWithOverflow(amount[0], @divTrunc(time_part, per_unit));
    if (total[1] != 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a span representable in the requested unit", .actual = "a span too large for the requested unit" });
    return makeLong(rt, total[0]);
}

/// Shift the date-time by whole days (epoch-day field only; time-of-day kept).
/// Shared by plus/minusDays + plus/minusWeeks.
fn addDays(rt: *Runtime, self: Value, days: i64) !Value {
    return make(rt, epochDayOf(self) + days, nanoOfDayOf(self));
}

/// Shift the date-time by `delta_ns` nanoseconds, carrying/borrowing whole
/// days into the epoch-day field. `@mod` keeps nano_of_day in [0, DAY_NS) and
/// `@divFloor` carries the borrow correctly for a negative total. Shared by
/// plus/minus Hours/Minutes/Seconds/Nanos.
fn addNanos(rt: *Runtime, self: Value, delta_ns: i64) !Value {
    const total = nanoOfDayOf(self) + delta_ns;
    const new_epoch_day = epochDayOf(self) + @divFloor(total, DAY_NS);
    const new_nano_of_day = @mod(total, DAY_NS);
    return make(rt, new_epoch_day, new_nano_of_day);
}

/// `(.plusDays d n)` — `n` days later (JVM `LocalDateTime.plusDays`).
fn plusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addDays(rt, args[0], args[1].asInteger());
}

/// `(.minusDays d n)` — `n` days earlier (JVM `LocalDateTime.minusDays`).
fn minusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addDays(rt, args[0], -args[1].asInteger());
}

/// `(.plusWeeks d n)` — `7*n` days later (JVM `LocalDateTime.plusWeeks`).
fn plusWeeksFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusWeeks", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusWeeks", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addDays(rt, args[0], 7 * args[1].asInteger());
}

/// `(.minusWeeks d n)` — `7*n` days earlier (JVM `LocalDateTime.minusWeeks`).
fn minusWeeksFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusWeeks", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusWeeks", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addDays(rt, args[0], -7 * args[1].asInteger());
}

/// `(.plusHours d n)` — `n` hours later, crossing midnight (JVM `LocalDateTime.plusHours`).
fn plusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], args[1].asInteger() * HOUR_NS);
}

/// `(.minusHours d n)` — `n` hours earlier, crossing midnight (JVM `LocalDateTime.minusHours`).
fn minusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], -args[1].asInteger() * HOUR_NS);
}

/// `(.plusMinutes d n)` — `n` minutes later, crossing midnight (JVM `LocalDateTime.plusMinutes`).
fn plusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], args[1].asInteger() * MIN_NS);
}

/// `(.minusMinutes d n)` — `n` minutes earlier, crossing midnight (JVM `LocalDateTime.minusMinutes`).
fn minusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], -args[1].asInteger() * MIN_NS);
}

/// `(.plusSeconds d n)` — `n` seconds later, crossing midnight (JVM `LocalDateTime.plusSeconds`).
fn plusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], args[1].asInteger() * SEC_NS);
}

/// `(.minusSeconds d n)` — `n` seconds earlier, crossing midnight (JVM `LocalDateTime.minusSeconds`).
fn minusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], -args[1].asInteger() * SEC_NS);
}

/// `(.plusNanos d n)` — `n` nanoseconds later, crossing midnight (JVM `LocalDateTime.plusNanos`).
fn plusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], args[1].asInteger());
}

/// `(.minusNanos d n)` — `n` nanoseconds earlier, crossing midnight (JVM `LocalDateTime.minusNanos`).
fn minusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addNanos(rt, args[0], -args[1].asInteger());
}

/// `(.plusMonths d n)` — `n` calendar months later on the DATE part (day
/// clamps to the new month's length), time-of-day kept (JVM `LocalDateTime.plusMonths`).
fn plusMonthsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMonths", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMonths", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, instant.addMonthsToEpochDay(epochDayOf(args[0]), args[1].asInteger()), nanoOfDayOf(args[0]));
}

/// `(.minusMonths d n)` — `n` calendar months earlier on the DATE part (JVM `LocalDateTime.minusMonths`).
fn minusMonthsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMonths", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMonths", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, instant.addMonthsToEpochDay(epochDayOf(args[0]), -args[1].asInteger()), nanoOfDayOf(args[0]));
}

/// `(.plusYears d n)` — `n` calendar years later on the DATE part (Feb-29 clamp),
/// time-of-day kept (JVM `LocalDateTime.plusYears`).
fn plusYearsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusYears", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusYears", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, instant.addYearsToEpochDay(epochDayOf(args[0]), args[1].asInteger()), nanoOfDayOf(args[0]));
}

/// `(.minusYears d n)` — `n` calendar years earlier on the DATE part (JVM `LocalDateTime.minusYears`).
fn minusYearsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusYears", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusYears", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, instant.addYearsToEpochDay(epochDayOf(args[0]), -args[1].asInteger()), nanoOfDayOf(args[0]));
}

const NS_PER_SEC: i128 = 1_000_000_000;

/// `(.plus d dur)` — the date-time shifted forward by a Duration (JVM
/// `LocalDateTime.plus(TemporalAmount)`), carrying whole days into epoch-day.
/// Distinct from `plusSeconds` (long arg): here the arg is a Duration value.
fn plusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plus", args, 2, loc);
    if (!duration_value.isDuration(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".plus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    const dur_ns = @as(i128, duration_value.secondsOf(args[1])) * NS_PER_SEC + duration_value.nanosOf(args[1]);
    const total = @as(i128, nanoOfDayOf(args[0])) + dur_ns;
    const new_epoch_day = epochDayOf(args[0]) + @as(i64, @intCast(@divFloor(total, @as(i128, DAY_NS))));
    return make(rt, new_epoch_day, @intCast(@mod(total, @as(i128, DAY_NS))));
}

/// `(.minus d dur)` — the date-time shifted backward by a Duration (JVM
/// `LocalDateTime.minus(TemporalAmount)`).
fn minusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minus", args, 2, loc);
    if (!duration_value.isDuration(rt, args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".minus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    const dur_ns = @as(i128, duration_value.secondsOf(args[1])) * NS_PER_SEC + duration_value.nanosOf(args[1]);
    const total = @as(i128, nanoOfDayOf(args[0])) - dur_ns;
    const new_epoch_day = epochDayOf(args[0]) + @as(i64, @intCast(@divFloor(total, @as(i128, DAY_NS))));
    return make(rt, new_epoch_day, @intCast(@mod(total, @as(i128, DAY_NS))));
}

/// The per-Runtime canonical LocalDateTime descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "LocalDateTime"` so
/// `(class …)` prints the simple name (AD-003 / no-JVM);
/// `temporal_print = .iso_local_date_time` drives the bare ISO-local print form.
/// Carries the instance methods.
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.local_date_time_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "LocalDateTime",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .temporal_print = .iso_local_date_time,
    };
    const specs = .{
        .{ "getYear", &getYearFn },
        .{ "getMonthValue", &getMonthValueFn },
        .{ "getDayOfMonth", &getDayOfMonthFn },
        .{ "getDayOfWeek", &getDayOfWeekFn },
        .{ "getMonth", &getMonthFn },
        .{ "getDayOfYear", &getDayOfYearFn },
        .{ "getHour", &getHourFn },
        .{ "getMinute", &getMinuteFn },
        .{ "getSecond", &getSecondFn },
        .{ "getNano", &getNanoFn },
        .{ "toLocalDate", &toLocalDateFn },
        .{ "toLocalTime", &toLocalTimeFn },
        .{ "plusDays", &plusDaysFn },
        .{ "minusDays", &minusDaysFn },
        .{ "plusWeeks", &plusWeeksFn },
        .{ "minusWeeks", &minusWeeksFn },
        .{ "plusHours", &plusHoursFn },
        .{ "minusHours", &minusHoursFn },
        .{ "plusMinutes", &plusMinutesFn },
        .{ "minusMinutes", &minusMinutesFn },
        .{ "plusSeconds", &plusSecondsFn },
        .{ "minusSeconds", &minusSecondsFn },
        .{ "plusNanos", &plusNanosFn },
        .{ "minusNanos", &minusNanosFn },
        .{ "plusMonths", &plusMonthsFn },
        .{ "minusMonths", &minusMonthsFn },
        .{ "plusYears", &plusYearsFn },
        .{ "minusYears", &minusYearsFn },
        .{ "isBefore", &isBeforeFn },
        .{ "isAfter", &isAfterFn },
        .{ "isEqual", &isEqualFn },
        .{ "until", &untilFn },
        .{ "plus", &plusFn },
        .{ "minus", &minusFn },
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
    rt.local_date_time_descriptor = td;
    return td;
}

/// Build a LocalDateTime from `epoch_day` (signed) + `nano_of_day`
/// (in [0, 86_400_000_000_000)). Two typed_instance fields.
pub fn make(rt: *Runtime, epoch_day: i64, nano_of_day: i64) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(epoch_day), Value.initInteger(nano_of_day) });
}

/// True when `v` is a LocalDateTime (carries the per-Runtime descriptor).
pub fn isLocalDateTime(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.local_date_time_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
}

/// The `epoch_day` field. Caller must have checked `isLocalDateTime`.
pub fn epochDayOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The `nano_of_day` field. Caller must have checked `isLocalDateTime`.
pub fn nanoOfDayOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[1].asInteger();
}

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.local_date_time_descriptor) |td| {
        for (td.method_table) |e| rt.gc.infra.free(e.method_name);
        if (td.method_table.len > 0) rt.gc.infra.free(td.method_table);
        rt.gc.infra.destroy(td);
        rt.local_date_time_descriptor = null;
    }
}

/// Format a LocalDateTime (`epoch_day` signed + `nano_of_day` in
/// [0, 86_400_000_000_000)) as the bare ISO local date-time string clj's
/// `(str ldt)` emits — `formatLocalDate ++ "T" ++ formatLocalTime` (the two
/// halves it shares with LocalDate / LocalTime, both in `instant.zig` the
/// F-009 neutral home). `buf` must be ≥ 35 bytes; returns the written slice.
/// Year is assumed [0, 9999] (4-digit pad).
pub fn formatLocalDateTime(buf: []u8, epoch_day: i64, nano_of_day: i64) []const u8 {
    const date = instant.formatLocalDate(buf, epoch_day);
    var len = date.len;
    buf[len] = 'T';
    len += 1;
    const time = instant.formatLocalTime(buf[len..], nano_of_day);
    return buf[0 .. len + time.len];
}

// --- tests ---

const testing = std.testing;

test "LocalDateTime value: make / isLocalDateTime / accessors + temporal_print set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const epoch_day = instant.daysFromCivil(2024, 3, 9);
    const nod: i64 = ((14 * 60 + 5) * 60 + 45) * 1_000_000_000 + 123_456_789;
    const d = try make(&rt, epoch_day, nod);
    try testing.expect(d.tag() == .typed_instance);
    try testing.expect(isLocalDateTime(&rt, d));
    try testing.expectEqual(epoch_day, epochDayOf(d));
    try testing.expectEqual(nod, nanoOfDayOf(d));
    try testing.expect(d.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_local_date_time);
    try testing.expect(!isLocalDateTime(&rt, Value.initInteger(5)));
}

test "formatLocalDateTime: conditional seconds + variable fraction" {
    var buf: [40]u8 = undefined;
    const d0 = instant.daysFromCivil(2024, 1, 1);
    // h:mm only — sec == 0 && nano == 0
    try testing.expectEqualStrings("2024-01-01T12:30", formatLocalDateTime(&buf, d0, (12 * 60 + 30) * 60_000_000_000));
    // :ss appended — sec != 0
    try testing.expectEqualStrings("2024-01-01T12:30:45", formatLocalDateTime(&buf, d0, ((12 * 60 + 30) * 60 + 45) * 1_000_000_000));
    // :ss + 3-digit fraction — whole millisecond nano
    try testing.expectEqualStrings("2024-01-01T12:30:45.500", formatLocalDateTime(&buf, d0, ((12 * 60 + 30) * 60 + 45) * 1_000_000_000 + 500_000_000));
    // 9-digit fraction — sub-microsecond nano (sec != 0 so :ss present)
    try testing.expectEqualStrings("2024-03-09T14:05:45.123456789", formatLocalDateTime(&buf, instant.daysFromCivil(2024, 3, 9), ((14 * 60 + 5) * 60 + 45) * 1_000_000_000 + 123_456_789));
    // midnight — both zero, no :ss
    try testing.expectEqualStrings("2024-06-15T00:00", formatLocalDateTime(&buf, instant.daysFromCivil(2024, 6, 15), 0));
    // nano != 0 but sec == 0 — :00 still appended (sec-or-nano gate), then fraction
    try testing.expectEqualStrings("2024-01-01T12:30:00.250", formatLocalDateTime(&buf, d0, (12 * 60 + 30) * 60_000_000_000 + 250_000_000));
}
