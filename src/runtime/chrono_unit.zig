// SPDX-License-Identifier: EPL-2.0
//! `java.time.temporal.ChronoUnit` enum-constant singletons (keyword
//! `chrono_unit`) — neutral so the analyzer (static-field resolve) and
//! `Runtime.deinit` reach the singletons without importing the `runtime/java/`
//! surface tree (zone rule). The surface (`runtime/java/time/ChronoUnit.zig`)
//! owns the descriptor + static-field table + methods; this file owns the
//! canonical ordinal↔name↔display mapping + the process-lifetime singletons.
//!
//! Each constant is a `.host_instance` (state[0]=ordinal), cached on an `rt`
//! slot — same discipline as RoundingMode / Locale. The second host-enum after
//! RoundingMode; the eventual general host-enum mechanism (D-510) folds both.
//! Distinct from RoundingMode in that `toString` is the DISPLAY name ("Days"),
//! while `.name` is the enum name ("DAYS").

const Value = @import("value/value.zig").Value;
const HeapHeader = @import("value/value.zig").HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const host_instance = @import("host_instance.zig");

/// The 16 JVM `ChronoUnit` constants, ordinals matching JVM exactly.
pub const COUNT = 16;

/// Enum-constant name for `ordinal` ("DAYS") — the `.name` / `(.name u)` text.
pub fn name(ordinal: u8) []const u8 {
    return switch (ordinal) {
        0 => "NANOS",
        1 => "MICROS",
        2 => "MILLIS",
        3 => "SECONDS",
        4 => "MINUTES",
        5 => "HOURS",
        6 => "HALF_DAYS",
        7 => "DAYS",
        8 => "WEEKS",
        9 => "MONTHS",
        10 => "YEARS",
        11 => "DECADES",
        12 => "CENTURIES",
        13 => "MILLENNIA",
        14 => "ERAS",
        15 => "FOREVER",
        else => unreachable,
    };
}

/// Display name for `ordinal` ("Days", "HalfDays") — the `(str u)` / `.toString`
/// text (JVM `ChronoUnit.toString()` returns the display name, not the enum name).
pub fn displayName(ordinal: u8) []const u8 {
    return switch (ordinal) {
        0 => "Nanos",
        1 => "Micros",
        2 => "Millis",
        3 => "Seconds",
        4 => "Minutes",
        5 => "Hours",
        6 => "HalfDays",
        7 => "Days",
        8 => "Weeks",
        9 => "Months",
        10 => "Years",
        11 => "Decades",
        12 => "Centuries",
        13 => "Millennia",
        14 => "Eras",
        15 => "Forever",
        else => unreachable,
    };
}

/// The process-lifetime ChronoUnit singleton for `ordinal` (0-15) — allocated
/// once on `gc.infra` + cached on `rt.chrono_units[ordinal]`. The descriptor is
/// the surface one in `rt.types` (registered at startup).
pub fn singleton(rt: *Runtime, ordinal: u8) !Value {
    const slot = &rt.chrono_units[ordinal];
    if (!slot.isNil()) return slot.*;
    const td = rt.types.get("java.time.temporal.ChronoUnit") orelse return error.InternalError;
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ ordinal, 0, 0, 0 },
    };
    slot.* = Value.encodeHeapPtr(.host_instance, inst);
    return slot.*;
}

/// Release all ChronoUnit singletons (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitSingletons(rt: *Runtime) void {
    for (&rt.chrono_units) |*slot| {
        if (slot.isNil()) continue;
        rt.gc.infra.destroy(@constCast(host_instance.asHostInstance(slot.*)));
        slot.* = .nil_val;
    }
}
