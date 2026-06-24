// SPDX-License-Identifier: EPL-2.0
//! `java.math.RoundingMode` enum-constant singletons (keyword `rounding_mode`)
//! — neutral so the analyzer (static-field resolve) and `Runtime.deinit` reach
//! the singletons without importing the `runtime/java/` surface tree (zone
//! rule). The surface (`runtime/java/math/RoundingMode.zig`) owns the
//! descriptor + static-field table; this file owns the canonical
//! name↔ordinal mapping (the SSOT both the RoundingMode enum table AND
//! BigDecimal's deprecated `ROUND_*` int table generate from, ADR-0160) and the
//! process-lifetime singletons.
//!
//! Each constant is a `.host_instance` whose `state[0]` carries the ordinal
//! (0-7), allocated once on `gc.infra` (never GC-swept) + cached on an `rt`
//! slot — same discipline as the Locale singletons. The cache gives `=` /
//! `identical?` parity (clj: `(= RoundingMode/HALF_UP RoundingMode/HALF_UP)` is
//! true; the constant is NEVER `=` to its int ordinal, unlike the int-ordinal
//! anti-pattern this file deliberately avoids).

const Value = @import("value/value.zig").Value;
const HeapHeader = @import("value/value.zig").HeapHeader;
const Runtime = @import("runtime.zig").Runtime;
const host_instance = @import("host_instance.zig");

/// The JVM `java.math.RoundingMode` enum, ordinals matching JVM exactly. These
/// ordinals also equal BigDecimal's deprecated `ROUND_*` int constants — the
/// single fact both static-field tables are generated from (no dual source).
pub const Mode = enum(u8) {
    up = 0,
    down = 1,
    ceiling = 2,
    floor = 3,
    half_up = 4,
    half_down = 5,
    half_even = 6,
    unnecessary = 7,
};

pub const COUNT = 8;

/// Bare JVM enum-constant name for `ordinal` ("HALF_UP" etc) — the
/// `(str RoundingMode/X)` / `.toString` text, and the `ROUND_<name>` suffix
/// BigDecimal's int table reuses. comptime-evaluable (string-literal switch).
pub fn name(ordinal: u8) []const u8 {
    return switch (@as(Mode, @enumFromInt(ordinal))) {
        .up => "UP",
        .down => "DOWN",
        .ceiling => "CEILING",
        .floor => "FLOOR",
        .half_up => "HALF_UP",
        .half_down => "HALF_DOWN",
        .half_even => "HALF_EVEN",
        .unnecessary => "UNNECESSARY",
    };
}

/// The process-lifetime RoundingMode singleton for `ordinal` (0-7) — allocated
/// once on `gc.infra` + cached on `rt.rounding_modes[ordinal]`. The descriptor
/// is the surface one in `rt.types` (registered by `installAll` at startup, so
/// present by the time a `RoundingMode/X` static field is first resolved).
pub fn singleton(rt: *Runtime, ordinal: u8) !Value {
    const slot = &rt.rounding_modes[ordinal];
    if (!slot.isNil()) return slot.*;
    const td = rt.types.get("java.math.RoundingMode") orelse return error.InternalError;
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ ordinal, 0, 0, 0 },
    };
    slot.* = Value.encodeHeapPtr(.host_instance, inst);
    return slot.*;
}

/// Release all RoundingMode singletons (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitSingletons(rt: *Runtime) void {
    for (&rt.rounding_modes) |*slot| {
        if (slot.isNil()) continue;
        rt.gc.infra.destroy(@constCast(host_instance.asHostInstance(slot.*)));
        slot.* = .nil_val;
    }
}
