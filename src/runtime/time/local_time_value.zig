// SPDX-License-Identifier: EPL-2.0
//! `java.time.LocalTime` VALUE (D-462) — a timezone-agnostic time-of-day.
//!
//! Mirrors the LocalDate model (`local_date_value.zig`): a no-slot cljw-native
//! `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag) carrying ONE
//! integer field — `nano_of_day` (in [0, 86_400_000_000_000)) — plus the ONE
//! canonical `rt.types["java.time.LocalTime"]` descriptor (ADR-0174: shared
//! with the `java/time/LocalTime.zig` static surface) whose `temporal_print =
//! .iso_local_time` makes the printer emit the bare ISO local time string
//! (NO `#tag`, no quotes — clj's `(str lt)` form). The time format/parse
//! halves are reused from `instant.zig` (F-009 neutral home); the Java
//! `java.time.LocalTime` static surface mints these from above.
//!
//! Distinct from the other temporal types by the descriptor's fqcn (so `=` /
//! print / `(class …)` discriminate) and by carrying the instance methods
//! getHour / getMinute / getSecond / getNano.

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

/// `(.getHour t)` — the hour-of-day 0..23 (JVM `LocalTime.getHour`).
fn getHourFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getHour", args, 1, loc);
    return Value.initInteger(@divTrunc(nanoOfDayOf(args[0]), 3_600_000_000_000));
}

/// `(.getMinute t)` — the minute-of-hour 0..59 (JVM `LocalTime.getMinute`).
fn getMinuteFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getMinute", args, 1, loc);
    return Value.initInteger(@rem(@divTrunc(nanoOfDayOf(args[0]), 60_000_000_000), 60));
}

/// `(.getSecond t)` — the second-of-minute 0..59 (JVM `LocalTime.getSecond`).
fn getSecondFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getSecond", args, 1, loc);
    return Value.initInteger(@rem(@divTrunc(nanoOfDayOf(args[0]), 1_000_000_000), 60));
}

/// `(.getNano t)` — the nanosecond-of-second 0..999_999_999 (JVM
/// `LocalTime.getNano`).
fn getNanoFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getNano", args, 1, loc);
    return Value.initInteger(@rem(nanoOfDayOf(args[0]), 1_000_000_000));
}

/// `(.isBefore a b)` — true when `a` is before `b` (JVM `LocalTime.isBefore`).
fn isBeforeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isBefore", args, 2, loc);
    if (!isLocalTime(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isBefore", .expected = "LocalTime", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(nanoOfDayOf(args[0]) < nanoOfDayOf(args[1]));
}

/// `(.isAfter a b)` — true when `a` is after `b` (JVM `LocalTime.isAfter`).
fn isAfterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isAfter", args, 2, loc);
    if (!isLocalTime(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isAfter", .expected = "LocalTime", .actual = @tagName(args[1].tag()) });
    return Value.initBoolean(nanoOfDayOf(args[0]) > nanoOfDayOf(args[1]));
}

const DAY_NS: i128 = 86_400_000_000_000;
const HOUR_NS: i128 = 3_600_000_000_000;
const MIN_NS: i128 = 60_000_000_000;
const NS_PER_SEC: i128 = 1_000_000_000;

/// Shared wrap-add helper: shift `nano_of_day` by a signed nanosecond delta,
/// wrapping mod 24h. `@mod` against DAY_NS yields [0, DAY_NS) for both signs.
fn addWrap(rt: *Runtime, self: Value, delta_ns: i128) !Value {
    return make(rt, @intCast(@mod(@as(i128, nanoOfDayOf(self)) + delta_ns, DAY_NS)));
}

/// `(.plusHours t n)` — the time `n` hours later, wrapping mod 24h (JVM `LocalTime.plusHours`).
fn plusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], @as(i128, args[1].asInteger()) * HOUR_NS);
}

/// `(.minusHours t n)` — the time `n` hours earlier, wrapping mod 24h (JVM `LocalTime.minusHours`).
fn minusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], -@as(i128, args[1].asInteger()) * HOUR_NS);
}

/// `(.plusMinutes t n)` — the time `n` minutes later, wrapping mod 24h (JVM `LocalTime.plusMinutes`).
fn plusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], @as(i128, args[1].asInteger()) * MIN_NS);
}

/// `(.minusMinutes t n)` — the time `n` minutes earlier, wrapping mod 24h (JVM `LocalTime.minusMinutes`).
fn minusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], -@as(i128, args[1].asInteger()) * MIN_NS);
}

/// `(.plusSeconds t n)` — the time `n` seconds later, wrapping mod 24h (JVM `LocalTime.plusSeconds`).
fn plusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], @as(i128, args[1].asInteger()) * NS_PER_SEC);
}

/// `(.minusSeconds t n)` — the time `n` seconds earlier, wrapping mod 24h (JVM `LocalTime.minusSeconds`).
fn minusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], -@as(i128, args[1].asInteger()) * NS_PER_SEC);
}

/// `(.plusNanos t n)` — the time `n` nanoseconds later, wrapping mod 24h (JVM `LocalTime.plusNanos`).
fn plusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], @as(i128, args[1].asInteger()));
}

/// `(.minusNanos t n)` — the time `n` nanoseconds earlier, wrapping mod 24h (JVM `LocalTime.minusNanos`).
fn minusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addWrap(rt, args[0], -@as(i128, args[1].asInteger()));
}

/// The JVM-visible class name — also the `rt.types` registry key
/// (ADR-0174 D1: Java-surface-backed classes carry their JVM FQCN).
pub const FQCN = "java.time.LocalTime";

/// Append the LocalTime instance methods onto `td` (idempotent — guarded on
/// the `getHour` sentinel). Called by BOTH creation orders: the surface
/// `init` (production) and `configureDescriptor` (bare-Runtime unit tests).
pub fn ensureInstanceMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.lookupMethod(null, "getHour") != null) return;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getHour", &getHourFn },
        .{ "getMinute", &getMinuteFn },
        .{ "getSecond", &getSecondFn },
        .{ "getNano", &getNanoFn },
        .{ "isBefore", &isBeforeFn },
        .{ "isAfter", &isAfterFn },
        .{ "plusHours", &plusHoursFn },
        .{ "minusHours", &minusHoursFn },
        .{ "plusMinutes", &plusMinutesFn },
        .{ "minusMinutes", &minusMinutesFn },
        .{ "plusSeconds", &plusSecondsFn },
        .{ "minusSeconds", &minusSecondsFn },
        .{ "plusNanos", &plusNanosFn },
        .{ "minusNanos", &minusNanosFn },
    });
}

fn configureDescriptor(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.temporal_print = .iso_local_time; // bare ISO local-time print form
    try ensureInstanceMethods(td, gpa);
}

/// The ONE canonical LocalTime descriptor: `rt.types["java.time.LocalTime"]`
/// (ADR-0174 D2 merge — statics and instance values share it).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FQCN, &configureDescriptor);
}

/// Build a LocalTime from `nano_of_day` (in [0, 86_400_000_000_000)). One
/// typed_instance field.
pub fn make(rt: *Runtime, nano_of_day: i64) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{Value.initInteger(nano_of_day)});
}

/// True when `v` is a LocalTime (carries the canonical LocalTime descriptor,
/// recognised by fqcn — rt-free).
pub fn isLocalTime(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// The `nano_of_day` field. Caller must have checked `isLocalTime`.
pub fn nanoOfDayOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

// --- tests ---

const testing = std.testing;

test "LocalTime value: make / isLocalTime / accessors + temporal_print set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const nod: i64 = ((14 * 60 + 5) * 60 + 45) * 1_000_000_000 + 123_456_789;
    const t = try make(&rt, nod);
    try testing.expect(t.tag() == .typed_instance);
    try testing.expect(isLocalTime(t));
    try testing.expectEqual(nod, nanoOfDayOf(t));
    try testing.expect(t.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_local_time);
    try testing.expect(!isLocalTime(Value.initInteger(5)));
}
