// SPDX-License-Identifier: EPL-2.0
//! General host-enum mechanism (ADR-0161, D-510) — ONE comptime registry + ONE
//! flat cache for the JVM host enums (`java.math.RoundingMode`,
//! `java.time.temporal.ChronoUnit`, `java.time.DayOfWeek`, `java.time.Month`,
//! `java.util.concurrent.TimeUnit`, `java.time.temporal.ChronoField`), folding the former one-off `rounding_mode.zig` / `chrono_unit.zig` /
//! `time/day_of_week_value.zig` / `time/month_value.zig`.
//!
//! Neutral (keyword `host_enum`): the analyzer's static-field resolve + the
//! `.until` decoders + `Runtime.deinit` reach it without importing the
//! `runtime/java/` surface tree (zone rule). The surfaces own each descriptor +
//! its static-field table + methods; this file owns the canonical
//! name↔ordinal↔display↔value mapping + the process-lifetime singletons.
//!
//! Each constant is a per-(enum, ordinal) interned `.host_instance` (state[0] =
//! ordinal), allocated once on `gc.infra` (never GC-swept) + cached in the single
//! flat `rt.host_enum_consts` array indexed by `defs[idx].cache_base + ordinal`.
//! `singleton` is the SOLE minting point, so `=` / `identical?` parity is
//! structural — no getter can re-mint a fresh value (the bug the former
//! getter-minted DayOfWeek/Month had). The cache size is the comptime sum of the
//! registry counts (8+16+7+12+7+30 = 80), so another host enum is a one-row edit with
//! zero new `rt` fields.

const Value = @import("value/value.zig").Value;
const HeapHeader = @import("value/value.zig").HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const Env = @import("env.zig").Env;
const SourceLocation = @import("error/info.zig").SourceLocation;
const error_catalog = @import("error/catalog.zig");
const host_instance = @import("host_instance.zig");
const string_collection = @import("collection/string.zig");
const java_array = @import("collection/java_array.zig");

/// Registry index. Declaration order IS the flat-cache layout (`cache_base`
/// accumulates from it). The `StaticFieldValue.host_enum.enum_idx` u8 is
/// `@intFromEnum` of this.
pub const Idx = enum(u8) {
    rounding_mode = 0,
    chrono_unit = 1,
    day_of_week = 2,
    month = 3,
    time_unit = 4,
    chrono_field = 5,
};

// Canonical per-enum tables. `to_strings` == `names` except ChronoUnit, whose
// `toString` is the DISPLAY name ("Days", not "DAYS").
const ROUNDING_NAMES = [_][]const u8{ "UP", "DOWN", "CEILING", "FLOOR", "HALF_UP", "HALF_DOWN", "HALF_EVEN", "UNNECESSARY" };
const CHRONO_NAMES = [_][]const u8{ "NANOS", "MICROS", "MILLIS", "SECONDS", "MINUTES", "HOURS", "HALF_DAYS", "DAYS", "WEEKS", "MONTHS", "YEARS", "DECADES", "CENTURIES", "MILLENNIA", "ERAS", "FOREVER" };
const CHRONO_DISPLAY = [_][]const u8{ "Nanos", "Micros", "Millis", "Seconds", "Minutes", "Hours", "HalfDays", "Days", "Weeks", "Months", "Years", "Decades", "Centuries", "Millennia", "Eras", "Forever" };
const DOW_NAMES = [_][]const u8{ "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY" };
const MONTH_NAMES = [_][]const u8{ "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" };
// ChronoField: JVM declaration order (the ordinal); `toString` is the display
// name. `time/date_time_format.zig::Field` mirrors this order (comptime-pinned).
const CHRONO_FIELD_NAMES = [_][]const u8{ "NANO_OF_SECOND", "NANO_OF_DAY", "MICRO_OF_SECOND", "MICRO_OF_DAY", "MILLI_OF_SECOND", "MILLI_OF_DAY", "SECOND_OF_MINUTE", "SECOND_OF_DAY", "MINUTE_OF_HOUR", "MINUTE_OF_DAY", "HOUR_OF_AMPM", "CLOCK_HOUR_OF_AMPM", "HOUR_OF_DAY", "CLOCK_HOUR_OF_DAY", "AMPM_OF_DAY", "DAY_OF_WEEK", "ALIGNED_DAY_OF_WEEK_IN_MONTH", "ALIGNED_DAY_OF_WEEK_IN_YEAR", "DAY_OF_MONTH", "DAY_OF_YEAR", "EPOCH_DAY", "ALIGNED_WEEK_OF_MONTH", "ALIGNED_WEEK_OF_YEAR", "MONTH_OF_YEAR", "PROLEPTIC_MONTH", "YEAR_OF_ERA", "YEAR", "ERA", "INSTANT_SECONDS", "OFFSET_SECONDS" };
const CHRONO_FIELD_DISPLAY = [_][]const u8{ "NanoOfSecond", "NanoOfDay", "MicroOfSecond", "MicroOfDay", "MilliOfSecond", "MilliOfDay", "SecondOfMinute", "SecondOfDay", "MinuteOfHour", "MinuteOfDay", "HourOfAmPm", "ClockHourOfAmPm", "HourOfDay", "ClockHourOfDay", "AmPmOfDay", "DayOfWeek", "AlignedDayOfWeekInMonth", "AlignedDayOfWeekInYear", "DayOfMonth", "DayOfYear", "EpochDay", "AlignedWeekOfMonth", "AlignedWeekOfYear", "MonthOfYear", "ProlepticMonth", "YearOfEra", "Year", "Era", "InstantSeconds", "OffsetSeconds" };
const TIME_UNIT_NAMES = [_][]const u8{ "NANOSECONDS", "MICROSECONDS", "MILLISECONDS", "SECONDS", "MINUTES", "HOURS", "DAYS" };

pub const EnumDef = struct {
    /// FQCN — the `rt.types` key the singleton's descriptor is registered under.
    fqcn: []const u8,
    /// ordinal → enum-constant name (`.name`; also `(str)` for the non-display enums).
    names: []const []const u8,
    /// ordinal → `(str x)` / `.toString` form (== `names` except ChronoUnit display).
    to_strings: []const []const u8,
    /// `getValue` = ordinal + `value_base`; `null` = the enum has no `getValue`
    /// (RoundingMode / ChronoUnit). DayOfWeek/Month use 1 (ISO value = ordinal+1).
    value_base: ?i64,
    /// First flat-cache slot for this enum (accumulated at comptime).
    cache_base: u16,
};

/// The registry, with `cache_base` accumulated at comptime from declaration order.
pub const defs = build: {
    var d = [_]EnumDef{
        .{ .fqcn = "java.math.RoundingMode", .names = &ROUNDING_NAMES, .to_strings = &ROUNDING_NAMES, .value_base = null, .cache_base = 0 },
        .{ .fqcn = "java.time.temporal.ChronoUnit", .names = &CHRONO_NAMES, .to_strings = &CHRONO_DISPLAY, .value_base = null, .cache_base = 0 },
        .{ .fqcn = "java.time.DayOfWeek", .names = &DOW_NAMES, .to_strings = &DOW_NAMES, .value_base = 1, .cache_base = 0 },
        .{ .fqcn = "java.time.Month", .names = &MONTH_NAMES, .to_strings = &MONTH_NAMES, .value_base = 1, .cache_base = 0 },
        .{ .fqcn = "java.util.concurrent.TimeUnit", .names = &TIME_UNIT_NAMES, .to_strings = &TIME_UNIT_NAMES, .value_base = null, .cache_base = 0 },
        .{ .fqcn = "java.time.temporal.ChronoField", .names = &CHRONO_FIELD_NAMES, .to_strings = &CHRONO_FIELD_DISPLAY, .value_base = null, .cache_base = 0 },
    };
    var base: u16 = 0;
    for (&d) |*e| {
        e.cache_base = base;
        base += @intCast(e.names.len);
    }
    break :build d;
};

/// Flat-cache size = sum of all enum counts (8+16+7+12+7+30 = 80).
pub const TOTAL = blk: {
    var n: u16 = 0;
    for (defs) |e| n += @intCast(e.names.len);
    break :blk n;
};

/// Number of constants in `idx` (comptime-usable for a surface's static-field
/// array size).
pub fn count(idx: Idx) usize {
    return defs[@intFromEnum(idx)].names.len;
}

/// Enum-constant name for `(idx, ordinal)` ("HALF_UP" / "DAYS" / "MONDAY").
pub fn name(idx: Idx, ordinal: u8) []const u8 {
    return defs[@intFromEnum(idx)].names[ordinal];
}

/// `(str x)` / `.toString` form for `(idx, ordinal)` — the enum name, or the
/// DISPLAY name for ChronoUnit ("Days").
pub fn toStringOf(idx: Idx, ordinal: u8) []const u8 {
    return defs[@intFromEnum(idx)].to_strings[ordinal];
}

/// `(.getValue x)` for `(idx, ordinal)` — `null` when the enum has no getValue
/// (RoundingMode / ChronoUnit).
pub fn value(idx: Idx, ordinal: u8) ?i64 {
    const vb = defs[@intFromEnum(idx)].value_base orelse return null;
    return vb + ordinal;
}

/// The process-lifetime interned singleton for `(idx, ordinal)` — allocated once
/// on `gc.infra` + cached in `rt.host_enum_consts[cache_base + ordinal]`. The
/// SOLE minting point for every host-enum constant (static-field read, getter
/// return, method receiver), so identity is canonical. The descriptor is the
/// surface one in `rt.types` (registered by `installAll` at startup).
pub fn singleton(rt: *Runtime, idx: Idx, ordinal: u8) !Value {
    const def = &defs[@intFromEnum(idx)];
    const slot = &rt.host_enum_consts[def.cache_base + ordinal];
    if (!slot.isNil()) return slot.*;
    const td = rt.types.get(def.fqcn) orelse return error.InternalError;
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ ordinal, 0, 0, 0 },
    };
    slot.* = Value.encodeHeapPtr(.host_instance, inst);
    return slot.*;
}

/// Uniform static-method family for a host-enum surface (ADR-0174 D7):
/// `values` / `valueOf` / (`of` where the JVM has it — Month, DayOfWeek).
/// ONE generic body parameterized by the registry index (the F-013 way);
/// each surface's `init` appends thin entries pointing at its instantiation.
/// All three return the interned `singleton` constants, so identity parity
/// with the static-field reads holds by construction.
pub fn Statics(comptime idx: Idx) type {
    const def = comptime &defs[@intFromEnum(idx)];
    return struct {
        /// `(Enum/values)` — a cljw Java array of the constants in ordinal
        /// order (JVM `values()` returns `Enum[]`).
        pub fn values(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity(def.fqcn ++ "/values", args, 0, loc);
            var buf: [def.names.len]Value = undefined;
            for (&buf, 0..) |*slot, ord| slot.* = try singleton(rt, idx, @intCast(ord));
            return java_array.fromSlice(rt, &buf);
        }

        /// `(Enum/valueOf "NAME")` — the constant with exactly that name; an
        /// unknown name raises `.value_error` (JVM IllegalArgumentException).
        pub fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = env;
            try error_catalog.checkArity(def.fqcn ++ "/valueOf", args, 1, loc);
            if (args[0].tag() != .string)
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = def.fqcn ++ "/valueOf", .expected = "string", .actual = @tagName(args[0].tag()) });
            const s = string_collection.asString(args[0]);
            for (def.names, 0..) |nm, ord| {
                if (std.mem.eql(u8, nm, s)) return singleton(rt, idx, @intCast(ord));
            }
            return error_catalog.raise(.arg_value_invalid, loc, .{ .fn_name = def.fqcn ++ "/valueOf", .expected = "a " ++ def.fqcn ++ " constant name", .actual = s });
        }

        /// `(Enum/of n)` — the constant with ISO value `n` (Month 1-12 /
        /// DayOfWeek 1-7). Referenced only by surfaces whose enum carries a
        /// `value_base` (the comptime assert pins that).
        pub fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            comptime std.debug.assert(def.value_base != null);
            _ = env;
            try error_catalog.checkArity(def.fqcn ++ "/of", args, 1, loc);
            if (args[0].tag() != .integer)
                return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = def.fqcn ++ "/of", .expected = "integer", .actual = @tagName(args[0].tag()) });
            const base = comptime def.value_base.?;
            const v = args[0].asInteger();
            if (v < base or v >= base + def.names.len)
                return error_catalog.raise(.arg_value_invalid, loc, .{
                    .fn_name = def.fqcn ++ "/of",
                    .expected = std.fmt.comptimePrint("a value in {d}..{d}", .{ base, base + def.names.len - 1 }),
                    .actual = "an out-of-range value",
                });
            return singleton(rt, idx, @intCast(v - base));
        }
    };
}

/// Release all interned host-enum singletons (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitConsts(rt: *Runtime) void {
    for (&rt.host_enum_consts) |*slot| {
        if (slot.isNil()) continue;
        rt.gc.infra.destroy(@constCast(host_instance.asHostInstance(slot.*)));
        slot.* = .nil_val;
    }
}

// --- tests ---

const std = @import("std");
const testing = std.testing;

test "host_enum registry: cache_base accumulation + TOTAL + name/toString/value" {
    // Counts: 8 + 16 + 7 + 12 + 7 + 30 = 80, non-overlapping flat-cache windows.
    try testing.expectEqual(@as(u16, 80), TOTAL);
    try testing.expectEqual(@as(usize, 30), count(.chrono_field));
    try testing.expectEqual(@as(u16, 50), defs[@intFromEnum(Idx.chrono_field)].cache_base);
    try testing.expectEqualStrings("HOUR_OF_DAY", name(.chrono_field, 12));
    try testing.expectEqualStrings("HourOfDay", toStringOf(.chrono_field, 12));
    try testing.expectEqual(@as(usize, 8), count(.rounding_mode));
    try testing.expectEqual(@as(usize, 16), count(.chrono_unit));
    try testing.expectEqual(@as(usize, 7), count(.day_of_week));
    try testing.expectEqual(@as(usize, 12), count(.month));
    try testing.expectEqual(@as(usize, 7), count(.time_unit));
    try testing.expectEqual(@as(u16, 0), defs[@intFromEnum(Idx.rounding_mode)].cache_base);
    try testing.expectEqual(@as(u16, 8), defs[@intFromEnum(Idx.chrono_unit)].cache_base);
    try testing.expectEqual(@as(u16, 24), defs[@intFromEnum(Idx.day_of_week)].cache_base);
    try testing.expectEqual(@as(u16, 31), defs[@intFromEnum(Idx.month)].cache_base);
    try testing.expectEqual(@as(u16, 43), defs[@intFromEnum(Idx.time_unit)].cache_base);

    // name vs toString: ChronoUnit toString is the display name; others equal.
    try testing.expectEqualStrings("HALF_UP", name(.rounding_mode, 4));
    try testing.expectEqualStrings("HALF_UP", toStringOf(.rounding_mode, 4));
    try testing.expectEqualStrings("DAYS", name(.chrono_unit, 7));
    try testing.expectEqualStrings("Days", toStringOf(.chrono_unit, 7));
    try testing.expectEqualStrings("MONDAY", name(.day_of_week, 0));
    try testing.expectEqualStrings("DECEMBER", name(.month, 11));
    try testing.expectEqualStrings("MILLISECONDS", name(.time_unit, 2));
    try testing.expectEqualStrings("MILLISECONDS", toStringOf(.time_unit, 2));

    // getValue: DayOfWeek/Month = ordinal+1 (ISO); RoundingMode/ChronoUnit = none.
    try testing.expectEqual(@as(?i64, null), value(.rounding_mode, 4));
    try testing.expectEqual(@as(?i64, null), value(.chrono_unit, 7));
    try testing.expectEqual(@as(?i64, 1), value(.day_of_week, 0));
    try testing.expectEqual(@as(?i64, 7), value(.day_of_week, 6));
    try testing.expectEqual(@as(?i64, 12), value(.month, 11));
}
