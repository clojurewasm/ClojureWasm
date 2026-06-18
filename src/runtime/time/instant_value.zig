// SPDX-License-Identifier: EPL-2.0
//! `java.time.Instant` VALUE (D-462) — a nanosecond-precision instant.
//!
//! Mirrors the Timestamp model (`timestamp.zig`, ADR-0079): a no-slot
//! cljw-native `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag)
//! carrying TWO fields — second-aligned epoch-millis + the full
//! fractional-second in nanoseconds (0..999_999_999) — plus a per-Runtime
//! `.native` descriptor whose `temporal_print = .iso_instant` makes the printer emit the
//! bare `ISO_INSTANT` string (variable fraction + `Z`, NO `#tag`, no quotes —
//! clj's `(str instant)` form). The parse/format lives in the sibling
//! `instant.zig` (F-009 neutral home); the Java `java.time.Instant` static
//! surface (`runtime/java/time/Instant.zig`) mints these from above.
//!
//! Distinct from Date/Timestamp by the per-Runtime descriptor pointer (so `=` /
//! print / `(class …)` discriminate) and by carrying the instance methods
//! `.getEpochSecond` / `.getNano` / `.toEpochMilli`.

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

/// `(.getEpochSecond i)` — the whole seconds since the epoch (JVM
/// `Instant.getEpochSecond`). `epoch_ms` is second-aligned, but `@divFloor`
/// keeps it correct for any negative pre-epoch instant too.
fn getEpochSecondFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getEpochSecond", args, 1, loc);
    return Value.initInteger(@divFloor(epochMsOf(args[0]), 1000));
}

/// `(.getNano i)` — the sub-second fraction in nanoseconds 0..999_999_999
/// (JVM `Instant.getNano`).
fn getNanoFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getNano", args, 1, loc);
    return Value.initInteger(nanosOf(args[0]));
}

/// `(.toEpochMilli i)` — epoch-millis (JVM `Instant.toEpochMilli`): the whole
/// seconds × 1000 plus the millisecond part of the nanos fraction.
fn toEpochMilliFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("toEpochMilli", args, 1, loc);
    const secs = @divFloor(epochMsOf(args[0]), 1000);
    return Value.initInteger(secs * 1000 + @divFloor(@as(i64, nanosOf(args[0])), 1_000_000));
}

/// The per-Runtime canonical Instant descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "Instant"` so `(class …)`
/// prints the simple name (AD-003 / no-JVM); `temporal_print = .iso_instant` drives the
/// bare ISO_INSTANT print form. Carries the instance methods (the Instant
/// VALUE carries this descriptor, so instance dispatch resolves here).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.instant_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "Instant",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .temporal_print = .iso_instant,
    };
    const specs = .{
        .{ "getEpochSecond", &getEpochSecondFn },
        .{ "getNano", &getNanoFn },
        .{ "toEpochMilli", &toEpochMilliFn },
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
    rt.instant_descriptor = td;
    return td;
}

/// Build an Instant from second-aligned epoch-millis + the full
/// fractional-second nanos (0..999_999_999). Two typed_instance fields.
pub fn make(rt: *Runtime, epoch_ms: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(epoch_ms), Value.initInteger(nanos) });
}

/// True when `v` is an Instant (carries the per-Runtime Instant descriptor).
pub fn isInstant(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.instant_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
}

/// The second-aligned epoch-millis field. Caller must have checked `isInstant`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The fractional-second nanos field. Caller must have checked `isInstant`.
pub fn nanosOf(v: Value) i32 {
    return @intCast(v.decodePtr(*const TypedInstance).fields()[1].asInteger());
}

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.instant_descriptor) |td| {
        for (td.method_table) |e| rt.gc.infra.free(e.method_name);
        if (td.method_table.len > 0) rt.gc.infra.free(td.method_table);
        rt.gc.infra.destroy(td);
        rt.instant_descriptor = null;
    }
}

// --- tests ---

const testing = std.testing;

test "Instant value: make / isInstant / accessors + iso_instant set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    // ofEpochSecond(1704067200, 500000000): epoch_ms second-aligned, nanos full.
    const i = try make(&rt, 1_704_067_200_000, 500_000_000);
    try testing.expect(i.tag() == .typed_instance);
    try testing.expect(isInstant(&rt, i));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(i));
    try testing.expectEqual(@as(i32, 500_000_000), nanosOf(i));
    try testing.expect(i.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_instant);
    try testing.expect(!isInstant(&rt, Value.initInteger(5)));
}
