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
const duration_value = @import("duration_value.zig");
const host_instance = @import("../host_instance.zig");
const host_enum = @import("../host_enum.zig");
const big_int = @import("../numeric/big_int.zig");
const nb = @import("../value/nan_box.zig");

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

/// `(.isBefore a b)` — true when `a` precedes `b` (JVM `Instant.isBefore`).
/// Compares by (epoch-millis, then nanos); both args must be Instants.
fn isBeforeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isBefore", args, 2, loc);
    if (!isInstant(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isBefore", .expected = "Instant", .actual = @tagName(args[1].tag()) });
    const a_ms = epochMsOf(args[0]);
    const b_ms = epochMsOf(args[1]);
    return Value.initBoolean(a_ms < b_ms or (a_ms == b_ms and nanosOf(args[0]) < nanosOf(args[1])));
}

/// `(.isAfter a b)` — true when `a` follows `b` (JVM `Instant.isAfter`).
fn isAfterFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isAfter", args, 2, loc);
    if (!isInstant(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".isAfter", .expected = "Instant", .actual = @tagName(args[1].tag()) });
    const a_ms = epochMsOf(args[0]);
    const b_ms = epochMsOf(args[1]);
    return Value.initBoolean(a_ms > b_ms or (a_ms == b_ms and nanosOf(args[0]) > nanosOf(args[1])));
}

const NS_PER_SEC: i128 = 1_000_000_000;
const NS_PER_MS: i128 = 1_000_000;

/// An integer count Value: fixnum in the i48 window, else a promoted Long.
fn makeLong(rt: *Runtime, v: i64) !Value {
    if (v >= nb.NB_I48_MIN and v <= nb.NB_I48_MAX) return Value.initInteger(v);
    return big_int.allocFromI64(rt, v, .long);
}

/// `(.until a b unit)` — whole count of ChronoUnit `unit` between two instants
/// (JVM `Instant.until`). Instant has no civil date, so only the fixed-duration
/// units NANOS..DAYS (DAYS = 86_400 s) are supported; WEEKS and up raise
/// (UnsupportedTemporalTypeException). The total nanos uses i128 to avoid overflow.
fn untilFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("until", args, 3, loc);
    if (!isInstant(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "an Instant", .actual = @tagName(args[1].tag()) });
    if (args[2].tag() != .host_instance)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a ChronoUnit", .actual = @tagName(args[2].tag()) });
    const ord: u8 = @intCast(host_instance.asHostInstance(args[2]).state[0]);
    const per_unit: i128 = switch (ord) {
        0 => 1, // NANOS
        1 => 1_000, // MICROS
        2 => 1_000_000, // MILLIS
        3 => NS_PER_SEC, // SECONDS
        4 => 60 * NS_PER_SEC, // MINUTES
        5 => 3_600 * NS_PER_SEC, // HOURS
        6 => 43_200 * NS_PER_SEC, // HALF_DAYS
        7 => 86_400 * NS_PER_SEC, // DAYS (fixed 86_400 s, no civil date)
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a time-based ChronoUnit (NANOS..DAYS)", .actual = host_enum.name(.chrono_unit, ord) }),
    };
    const s1 = @divFloor(epochMsOf(args[0]), 1000);
    const s2 = @divFloor(epochMsOf(args[1]), 1000);
    const total_ns: i128 = (@as(i128, s2) - @as(i128, s1)) * NS_PER_SEC + (@as(i128, nanosOf(args[1])) - @as(i128, nanosOf(args[0])));
    const result: i128 = @divTrunc(total_ns, per_unit);
    if (result < std.math.minInt(i64) or result > std.math.maxInt(i64))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".until", .expected = "a span representable in the requested unit", .actual = "an out-of-range NANOS span" });
    return makeLong(rt, @intCast(result));
}

/// Shared add helper for `plusMillis` / `plusNanos` (and the minus* negations):
/// fold a nanosecond delta into the fractional-second field with a second-carry.
fn addFracNanos(rt: *Runtime, self: Value, delta_ns: i128) !Value {
    const total = @as(i128, nanosOf(self)) + delta_ns;
    const carry_sec = @divFloor(total, NS_PER_SEC);
    const new_ms = epochMsOf(self) + @as(i64, @intCast(carry_sec)) * 1000;
    return make(rt, new_ms, @intCast(@mod(total, NS_PER_SEC)));
}

/// `(.plusSeconds i n)` — the instant `n` seconds later (JVM `Instant.plusSeconds`).
fn plusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochMsOf(args[0]) + args[1].asInteger() * 1000, nanosOf(args[0]));
}

/// `(.minusSeconds i n)` — the instant `n` seconds earlier (JVM `Instant.minusSeconds`).
fn minusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, epochMsOf(args[0]) - args[1].asInteger() * 1000, nanosOf(args[0]));
}

/// `(.plusMillis i n)` — the instant `n` milliseconds later (JVM `Instant.plusMillis`).
fn plusMillisFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMillis", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMillis", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addFracNanos(rt, args[0], @as(i128, args[1].asInteger()) * NS_PER_MS);
}

/// `(.minusMillis i n)` — the instant `n` milliseconds earlier (JVM `Instant.minusMillis`).
fn minusMillisFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMillis", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMillis", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addFracNanos(rt, args[0], -@as(i128, args[1].asInteger()) * NS_PER_MS);
}

/// `(.plusNanos i n)` — the instant `n` nanoseconds later (JVM `Instant.plusNanos`).
fn plusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addFracNanos(rt, args[0], @as(i128, args[1].asInteger()));
}

/// `(.minusNanos i n)` — the instant `n` nanoseconds earlier (JVM `Instant.minusNanos`).
fn minusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return addFracNanos(rt, args[0], -@as(i128, args[1].asInteger()));
}

/// `(.plus i d)` — the instant shifted forward by a Duration (JVM
/// `Instant.plus(TemporalAmount)`). Distinct from `plusSeconds` (long arg):
/// here the arg is a Duration value.
fn plusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plus", args, 2, loc);
    if (!duration_value.isDuration(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".plus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    var new_epoch_ms = epochMsOf(args[0]) + duration_value.secondsOf(args[1]) * 1000;
    const total_ns = @as(i128, nanosOf(args[0])) + duration_value.nanosOf(args[1]);
    new_epoch_ms += @as(i64, @intCast(@divFloor(total_ns, NS_PER_SEC))) * 1000;
    return make(rt, new_epoch_ms, @intCast(@mod(total_ns, NS_PER_SEC)));
}

/// `(.minus i d)` — the instant shifted backward by a Duration (JVM
/// `Instant.minus(TemporalAmount)`).
fn minusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minus", args, 2, loc);
    if (!duration_value.isDuration(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".minus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    var new_epoch_ms = epochMsOf(args[0]) - duration_value.secondsOf(args[1]) * 1000;
    const total_ns = @as(i128, nanosOf(args[0])) - duration_value.nanosOf(args[1]);
    new_epoch_ms += @as(i64, @intCast(@divFloor(total_ns, NS_PER_SEC))) * 1000;
    return make(rt, new_epoch_ms, @intCast(@mod(total_ns, NS_PER_SEC)));
}

/// The JVM-visible class name — also the `rt.types` registry key
/// (ADR-0174 D1: Java-surface-backed classes carry their JVM FQCN).
pub const FQCN = "java.time.Instant";

/// Append the Instant instance methods onto `td` (idempotent — guarded on
/// the `getEpochSecond` sentinel). Called by BOTH creation orders: the
/// surface `init` (production) and `configureDescriptor` (bare-Runtime
/// unit tests).
pub fn ensureInstanceMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.lookupMethod(null, "getEpochSecond") != null) return;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getEpochSecond", &getEpochSecondFn },
        .{ "getNano", &getNanoFn },
        .{ "toEpochMilli", &toEpochMilliFn },
        .{ "isBefore", &isBeforeFn },
        .{ "isAfter", &isAfterFn },
        .{ "until", &untilFn },
        .{ "plusSeconds", &plusSecondsFn },
        .{ "minusSeconds", &minusSecondsFn },
        .{ "plusMillis", &plusMillisFn },
        .{ "minusMillis", &minusMillisFn },
        .{ "plusNanos", &plusNanosFn },
        .{ "minusNanos", &minusNanosFn },
        .{ "plus", &plusFn },
        .{ "minus", &minusFn },
    });
}

fn configureDescriptor(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.temporal_print = .iso_instant; // bare ISO_INSTANT print form
    try ensureInstanceMethods(td, gpa);
}

/// The ONE canonical Instant descriptor: `rt.types["java.time.Instant"]`
/// (ADR-0174 D2 merge — statics and instance values share it).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FQCN, &configureDescriptor);
}

/// Build an Instant from second-aligned epoch-millis + the full
/// fractional-second nanos (0..999_999_999). Two typed_instance fields.
pub fn make(rt: *Runtime, epoch_ms: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(epoch_ms), Value.initInteger(nanos) });
}

/// True when `v` is an Instant (carries the canonical Instant descriptor,
/// recognised by fqcn — rt-free).
pub fn isInstant(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// The second-aligned epoch-millis field. Caller must have checked `isInstant`.
pub fn epochMsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The fractional-second nanos field. Caller must have checked `isInstant`.
pub fn nanosOf(v: Value) i32 {
    return @intCast(v.decodePtr(*const TypedInstance).fields()[1].asInteger());
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
    try testing.expect(isInstant(i));
    try testing.expectEqual(@as(i64, 1_704_067_200_000), epochMsOf(i));
    try testing.expectEqual(@as(i32, 500_000_000), nanosOf(i));
    try testing.expect(i.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_instant);
    try testing.expect(!isInstant(Value.initInteger(5)));
}
