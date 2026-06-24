// SPDX-License-Identifier: EPL-2.0
//! General host-enum mechanism (ADR-0161, D-510) — ONE comptime registry + ONE
//! flat cache for the four JVM host enums (`java.math.RoundingMode`,
//! `java.time.temporal.ChronoUnit`, `java.time.DayOfWeek`, `java.time.Month`),
//! folding the former one-off `rounding_mode.zig` / `chrono_unit.zig` /
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
//! registry counts (8+16+7+12 = 43), so a fifth host enum is a one-row edit with
//! zero new `rt` fields.

const Value = @import("value/value.zig").Value;
const HeapHeader = @import("value/value.zig").HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const host_instance = @import("host_instance.zig");

/// Registry index. Declaration order IS the flat-cache layout (`cache_base`
/// accumulates from it). The `StaticFieldValue.host_enum.enum_idx` u8 is
/// `@intFromEnum` of this.
pub const Idx = enum(u8) {
    rounding_mode = 0,
    chrono_unit = 1,
    day_of_week = 2,
    month = 3,
};

// Canonical per-enum tables. `to_strings` == `names` except ChronoUnit, whose
// `toString` is the DISPLAY name ("Days", not "DAYS").
const ROUNDING_NAMES = [_][]const u8{ "UP", "DOWN", "CEILING", "FLOOR", "HALF_UP", "HALF_DOWN", "HALF_EVEN", "UNNECESSARY" };
const CHRONO_NAMES = [_][]const u8{ "NANOS", "MICROS", "MILLIS", "SECONDS", "MINUTES", "HOURS", "HALF_DAYS", "DAYS", "WEEKS", "MONTHS", "YEARS", "DECADES", "CENTURIES", "MILLENNIA", "ERAS", "FOREVER" };
const CHRONO_DISPLAY = [_][]const u8{ "Nanos", "Micros", "Millis", "Seconds", "Minutes", "Hours", "HalfDays", "Days", "Weeks", "Months", "Years", "Decades", "Centuries", "Millennia", "Eras", "Forever" };
const DOW_NAMES = [_][]const u8{ "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY" };
const MONTH_NAMES = [_][]const u8{ "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" };

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
    };
    var base: u16 = 0;
    for (&d) |*e| {
        e.cache_base = base;
        base += @intCast(e.names.len);
    }
    break :build d;
};

/// Flat-cache size = sum of all enum counts (8+16+7+12 = 43).
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
    // Counts: 8 + 16 + 7 + 12 = 43, non-overlapping flat-cache windows.
    try testing.expectEqual(@as(u16, 43), TOTAL);
    try testing.expectEqual(@as(usize, 8), count(.rounding_mode));
    try testing.expectEqual(@as(usize, 16), count(.chrono_unit));
    try testing.expectEqual(@as(usize, 7), count(.day_of_week));
    try testing.expectEqual(@as(usize, 12), count(.month));
    try testing.expectEqual(@as(u16, 0), defs[@intFromEnum(Idx.rounding_mode)].cache_base);
    try testing.expectEqual(@as(u16, 8), defs[@intFromEnum(Idx.chrono_unit)].cache_base);
    try testing.expectEqual(@as(u16, 24), defs[@intFromEnum(Idx.day_of_week)].cache_base);
    try testing.expectEqual(@as(u16, 31), defs[@intFromEnum(Idx.month)].cache_base);

    // name vs toString: ChronoUnit toString is the display name; others equal.
    try testing.expectEqualStrings("HALF_UP", name(.rounding_mode, 4));
    try testing.expectEqualStrings("HALF_UP", toStringOf(.rounding_mode, 4));
    try testing.expectEqualStrings("DAYS", name(.chrono_unit, 7));
    try testing.expectEqualStrings("Days", toStringOf(.chrono_unit, 7));
    try testing.expectEqualStrings("MONDAY", name(.day_of_week, 0));
    try testing.expectEqualStrings("DECEMBER", name(.month, 11));

    // getValue: DayOfWeek/Month = ordinal+1 (ISO); RoundingMode/ChronoUnit = none.
    try testing.expectEqual(@as(?i64, null), value(.rounding_mode, 4));
    try testing.expectEqual(@as(?i64, null), value(.chrono_unit, 7));
    try testing.expectEqual(@as(?i64, 1), value(.day_of_week, 0));
    try testing.expectEqual(@as(?i64, 7), value(.day_of_week, 6));
    try testing.expectEqual(@as(?i64, 12), value(.month, 11));
}
