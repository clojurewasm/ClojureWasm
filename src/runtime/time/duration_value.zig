// SPDX-License-Identifier: EPL-2.0
//! `java.time.Duration` VALUE (D-462) — a signed time span.
//!
//! Mirrors the Instant model (`instant_value.zig`): a no-slot cljw-native
//! `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag) carrying TWO
//! integer fields — `seconds` (signed) + `nanos` (0..999_999_999) — NORMALIZED
//! so the nanos fraction is non-negative and the seconds field carries the
//! sign. The ONE canonical `rt.types["java.time.Duration"]` descriptor
//! (ADR-0174: shared with the `java/time/Duration.zig` static surface) carries
//! `temporal_print = .iso_duration`, making the printer emit the bare ISO-8601
//! duration string (`PT…`, NO `#tag`, no quotes — clj's `(str duration)`
//! form). The PT-format itself (`formatDuration`) is self-contained here (no
//! civil calendar). The Java `java.time.Duration` static surface mints these
//! from above.
//!
//! Distinct from Instant/Date/Timestamp by the descriptor's fqcn (so `=` /
//! print / `(class …)` discriminate) and by carrying the instance methods
//! `.getSeconds` / `.getNano` / `.toMillis` / `.toMinutes`.

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
const instant_value = @import("instant_value.zig");
const local_date_time_value = @import("local_date_time_value.zig");
const local_time_value = @import("local_time_value.zig");

/// `(.getSeconds d)` — the whole seconds (signed) of the normalized span
/// (JVM `Duration.getSeconds`).
fn getSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getSeconds", args, 1, loc);
    return Value.initInteger(secondsOf(args[0]));
}

/// `(.getNano d)` — the sub-second fraction in nanoseconds 0..999_999_999
/// (JVM `Duration.getNano`; always non-negative after normalization).
fn getNanoFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getNano", args, 1, loc);
    return Value.initInteger(nanosOf(args[0]));
}

/// `(.toMillis d)` — the span in milliseconds (JVM `Duration.toMillis`):
/// `seconds * 1000` plus the millisecond part of the nanos fraction
/// (truncated toward zero, matching the JVM).
fn toMillisFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("toMillis", args, 1, loc);
    return Value.initInteger(secondsOf(args[0]) * 1000 + @divTrunc(@as(i64, nanosOf(args[0])), 1_000_000));
}

/// `(.toMinutes d)` — the span in whole minutes (JVM `Duration.toMinutes`):
/// `seconds / 60` truncated toward zero.
fn toMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("toMinutes", args, 1, loc);
    return Value.initInteger(@divTrunc(secondsOf(args[0]), 60));
}

/// `(.isZero d)` — true when the span is exactly zero (JVM `Duration.isZero`).
fn isZeroFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isZero", args, 1, loc);
    return Value.initBoolean(secondsOf(args[0]) == 0 and nanosOf(args[0]) == 0);
}

/// `(.isNegative d)` — true when the span is negative (JVM `Duration.isNegative`).
/// The seconds field carries the sign after normalization.
fn isNegativeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isNegative", args, 1, loc);
    return Value.initBoolean(secondsOf(args[0]) < 0);
}

/// `(.negated d)` — the span with its sign flipped (JVM `Duration.negated`).
/// Re-normalizes so the nanos fraction stays non-negative.
fn negatedFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("negated", args, 1, loc);
    return negate(rt, args[0]);
}

/// `(.abs d)` — the magnitude of the span (JVM `Duration.abs`). Returns the
/// receiver unchanged when non-negative; otherwise the negation.
fn absFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("abs", args, 1, loc);
    if (secondsOf(args[0]) < 0) return negate(rt, args[0]);
    return args[0];
}

/// Mint the normalized negation of a Duration value. Borrows one second when
/// the fraction is non-zero so the resulting nanos stay in 0..999_999_999.
fn negate(rt: *Runtime, v: Value) !Value {
    const neg_nanos = -@as(i64, nanosOf(v));
    const new_seconds = -secondsOf(v) + @divFloor(neg_nanos, 1_000_000_000);
    const new_nanos: i32 = @intCast(@mod(neg_nanos, 1_000_000_000));
    return make(rt, new_seconds, new_nanos);
}

const NS_PER_SEC: i128 = 1_000_000_000;
const NS_PER_MS: i128 = 1_000_000;

/// Mint a normalized Duration from a possibly-out-of-range (seconds,
/// nano_adjustment): the nano overflow folds into the seconds field so the
/// stored nanos stay in [0, 1e9). `@divFloor`/`@mod` keep it negative-safe.
fn normalize(rt: *Runtime, seconds: i64, nano_adj: i128) !Value {
    const new_seconds = @as(i128, seconds) + @divFloor(nano_adj, NS_PER_SEC);
    const new_nanos: i32 = @intCast(@mod(nano_adj, NS_PER_SEC));
    return make(rt, @intCast(new_seconds), new_nanos);
}

/// `(.plusSeconds d n)` — the span `n` seconds longer (JVM `Duration.plusSeconds`).
fn plusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) + args[1].asInteger(), nanosOf(args[0]));
}

/// `(.minusSeconds d n)` — the span `n` seconds shorter (JVM `Duration.minusSeconds`).
fn minusSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusSeconds", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusSeconds", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) - args[1].asInteger(), nanosOf(args[0]));
}

/// `(.plusMinutes d n)` — the span `n` minutes longer (JVM `Duration.plusMinutes`).
fn plusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) + args[1].asInteger() * 60, nanosOf(args[0]));
}

/// `(.minusMinutes d n)` — the span `n` minutes shorter (JVM `Duration.minusMinutes`).
fn minusMinutesFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMinutes", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMinutes", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) - args[1].asInteger() * 60, nanosOf(args[0]));
}

/// `(.plusHours d n)` — the span `n` hours longer (JVM `Duration.plusHours`).
fn plusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) + args[1].asInteger() * 3600, nanosOf(args[0]));
}

/// `(.minusHours d n)` — the span `n` hours shorter (JVM `Duration.minusHours`).
fn minusHoursFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusHours", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusHours", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) - args[1].asInteger() * 3600, nanosOf(args[0]));
}

/// `(.plusDays d n)` — the span `n` days longer (JVM `Duration.plusDays`).
fn plusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) + args[1].asInteger() * 86400, nanosOf(args[0]));
}

/// `(.minusDays d n)` — the span `n` days shorter (JVM `Duration.minusDays`).
fn minusDaysFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusDays", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusDays", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return make(rt, secondsOf(args[0]) - args[1].asInteger() * 86400, nanosOf(args[0]));
}

/// `(.plusMillis d n)` — the span `n` milliseconds longer (JVM `Duration.plusMillis`).
fn plusMillisFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusMillis", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusMillis", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]), @as(i128, nanosOf(args[0])) + @as(i128, args[1].asInteger()) * NS_PER_MS);
}

/// `(.minusMillis d n)` — the span `n` milliseconds shorter (JVM `Duration.minusMillis`).
fn minusMillisFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusMillis", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusMillis", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]), @as(i128, nanosOf(args[0])) - @as(i128, args[1].asInteger()) * NS_PER_MS);
}

/// `(.plusNanos d n)` — the span `n` nanoseconds longer (JVM `Duration.plusNanos`).
fn plusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "plusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]), @as(i128, nanosOf(args[0])) + @as(i128, args[1].asInteger()));
}

/// `(.minusNanos d n)` — the span `n` nanoseconds shorter (JVM `Duration.minusNanos`).
fn minusNanosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minusNanos", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "minusNanos", .expected = "integer", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]), @as(i128, nanosOf(args[0])) - @as(i128, args[1].asInteger()));
}

/// `(.plus d other)` — the sum of two spans (JVM `Duration.plus`).
fn plusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("plus", args, 2, loc);
    if (!isDuration(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".plus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]) + secondsOf(args[1]), @as(i128, nanosOf(args[0])) + @as(i128, nanosOf(args[1])));
}

/// `(.minus d other)` — the difference of two spans (JVM `Duration.minus`).
fn minusFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("minus", args, 2, loc);
    if (!isDuration(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".minus", .expected = "Duration", .actual = @tagName(args[1].tag()) });
    return normalize(rt, secondsOf(args[0]) - secondsOf(args[1]), @as(i128, nanosOf(args[0])) - @as(i128, nanosOf(args[1])));
}

/// `(.multipliedBy d n)` — the span scaled by `n` (JVM `Duration.multipliedBy`).
fn multipliedByFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("multipliedBy", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "multipliedBy", .expected = "integer", .actual = @tagName(args[1].tag()) });
    const total = (@as(i128, secondsOf(args[0])) * NS_PER_SEC + nanosOf(args[0])) * @as(i128, args[1].asInteger());
    return make(rt, @intCast(@divFloor(total, NS_PER_SEC)), @intCast(@mod(total, NS_PER_SEC)));
}

/// `(.dividedBy d n)` — the span divided by `n` (JVM `Duration.dividedBy`),
/// truncated toward zero.
fn dividedByFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("dividedBy", args, 2, loc);
    if (args[1].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "dividedBy", .expected = "integer", .actual = @tagName(args[1].tag()) });
    const total = @as(i128, secondsOf(args[0])) * NS_PER_SEC + nanosOf(args[0]);
    const q = @divTrunc(total, @as(i128, args[1].asInteger()));
    return make(rt, @intCast(@divFloor(q, NS_PER_SEC)), @intCast(@mod(q, NS_PER_SEC)));
}

const DAY_NS: i128 = 86_400_000_000_000;

/// `(java.time.Duration/between a b)` — the elapsed time `b - a` as a Duration
/// (JVM `Duration.between`). Both args must be the SAME temporal type
/// (Instant / LocalDateTime / LocalTime); a cross-type or non-temporal pair
/// raises `type_arg_invalid`, mirroring clj's throw on unsupported temporals.
pub fn betweenFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("between", args, 2, loc);
    const a = args[0];
    const b = args[1];
    if (instant_value.isInstant(a) and instant_value.isInstant(b)) {
        const a_ns = @as(i128, instant_value.epochMsOf(a)) * 1_000_000 + instant_value.nanosOf(a);
        const b_ns = @as(i128, instant_value.epochMsOf(b)) * 1_000_000 + instant_value.nanosOf(b);
        return makeFromNanos(rt, b_ns - a_ns);
    }
    if (local_date_time_value.isLocalDateTime(a) and local_date_time_value.isLocalDateTime(b)) {
        const a_ns = @as(i128, local_date_time_value.epochDayOf(a)) * DAY_NS + local_date_time_value.nanoOfDayOf(a);
        const b_ns = @as(i128, local_date_time_value.epochDayOf(b)) * DAY_NS + local_date_time_value.nanoOfDayOf(b);
        return makeFromNanos(rt, b_ns - a_ns);
    }
    if (local_time_value.isLocalTime(a) and local_time_value.isLocalTime(b)) {
        return makeFromNanos(rt, @as(i128, local_time_value.nanoOfDayOf(b)) - local_time_value.nanoOfDayOf(a));
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "between", .expected = "two temporals of the same type", .actual = @tagName(b.tag()) });
}

/// The JVM-visible class name — also the `rt.types` registry key
/// (ADR-0174 D1: Java-surface-backed classes carry their JVM FQCN).
pub const FQCN = "java.time.Duration";

/// Append the Duration instance methods onto `td` (idempotent — guarded on
/// the `getSeconds` sentinel). Called by BOTH creation orders: the surface
/// `init` (production) and `configureDescriptor` (bare-Runtime unit tests).
pub fn ensureInstanceMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.lookupMethod(null, "getSeconds") != null) return;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getSeconds", &getSecondsFn },
        .{ "getNano", &getNanoFn },
        .{ "toMillis", &toMillisFn },
        .{ "toMinutes", &toMinutesFn },
        .{ "isZero", &isZeroFn },
        .{ "isNegative", &isNegativeFn },
        .{ "negated", &negatedFn },
        .{ "abs", &absFn },
        .{ "plusSeconds", &plusSecondsFn },
        .{ "minusSeconds", &minusSecondsFn },
        .{ "plusMinutes", &plusMinutesFn },
        .{ "minusMinutes", &minusMinutesFn },
        .{ "plusHours", &plusHoursFn },
        .{ "minusHours", &minusHoursFn },
        .{ "plusDays", &plusDaysFn },
        .{ "minusDays", &minusDaysFn },
        .{ "plusMillis", &plusMillisFn },
        .{ "minusMillis", &minusMillisFn },
        .{ "plusNanos", &plusNanosFn },
        .{ "minusNanos", &minusNanosFn },
        .{ "plus", &plusFn },
        .{ "minus", &minusFn },
        .{ "multipliedBy", &multipliedByFn },
        .{ "dividedBy", &dividedByFn },
    });
}

fn configureDescriptor(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.temporal_print = .iso_duration; // bare `PT…` print form
    try ensureInstanceMethods(td, gpa);
}

/// The ONE canonical Duration descriptor: `rt.types["java.time.Duration"]`
/// (ADR-0174 D2 merge — statics and instance values share it).
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FQCN, &configureDescriptor);
}

/// Build a Duration from already-NORMALIZED `seconds` (signed) + `nanos`
/// (0..999_999_999). Two typed_instance fields. The factory surface
/// (`Duration.zig`) does the normalization before calling.
pub fn make(rt: *Runtime, seconds: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(seconds), Value.initInteger(nanos) });
}

/// Mint a normalized Duration from a total nanosecond span. `@divFloor`/`@mod`
/// give the canonical {seconds, nanos∈[0,1e9)} pair (negative-safe).
pub fn makeFromNanos(rt: *Runtime, total_ns: i128) !Value {
    return make(rt, @intCast(@divFloor(total_ns, NS_PER_SEC)), @intCast(@mod(total_ns, NS_PER_SEC)));
}

/// True when `v` is a Duration (carries the canonical Duration descriptor,
/// recognised by fqcn — rt-free).
pub fn isDuration(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, FQCN);
}

/// The whole-seconds (signed) field. Caller must have checked `isDuration`.
pub fn secondsOf(v: Value) i64 {
    return v.decodePtr(*const TypedInstance).fields()[0].asInteger();
}

/// The fractional-second nanos field (0..999_999_999). Caller must have
/// checked `isDuration`.
pub fn nanosOf(v: Value) i32 {
    return @intCast(v.decodePtr(*const TypedInstance).fields()[1].asInteger());
}

/// Format a normalized Duration (`seconds` signed, `nanos` in 0..999_999_999)
/// as the ISO-8601 duration string (`PT…`), a direct port of the JDK
/// `Duration.toString` algorithm. Self-contained — no civil calendar. `buf`
/// must be at least 40 bytes; returns the written slice (a sub-slice of `buf`).
pub fn formatDuration(buf: []u8, seconds: i64, nanos: i32) []const u8 {
    if (seconds == 0 and nanos == 0) {
        @memcpy(buf[0..4], "PT0S");
        return buf[0..4];
    }
    const hours = @divTrunc(seconds, 3600);
    const minutes = @divTrunc(@rem(seconds, 3600), 60);
    const secs = @rem(seconds, 60); // signed, range (-60, 60)

    var len: usize = 0;
    buf[0] = 'P';
    buf[1] = 'T';
    len = 2;

    if (hours != 0) {
        len += (std.fmt.bufPrint(buf[len..], "{d}H", .{hours}) catch unreachable).len;
    }
    if (minutes != 0) {
        len += (std.fmt.bufPrint(buf[len..], "{d}M", .{minutes}) catch unreachable).len;
    }
    if (secs == 0 and nanos == 0 and len > 2) {
        return buf[0..len];
    }

    // Integer seconds part. A negative span with a positive nanos fraction
    // (e.g. -0.5s = {-1, 500000000}) borrows one second so the fraction reads
    // forward: -1s+0.5s prints as "-0.5", and exactly -1s+frac prints "-0".
    if (secs < 0 and nanos > 0) {
        if (secs == -1) {
            buf[len] = '-';
            buf[len + 1] = '0';
            len += 2;
        } else {
            len += (std.fmt.bufPrint(buf[len..], "{d}", .{secs + 1}) catch unreachable).len;
        }
    } else {
        len += (std.fmt.bufPrint(buf[len..], "{d}", .{secs}) catch unreachable).len;
    }

    if (nanos > 0) {
        const pos = len; // index of the fraction's leading digit (overwritten by '.')
        // A 10-digit value leading with '1' or '2' so the leading zeros of the
        // fraction are preserved; `pos` (the leading '1'/'2') becomes '.'.
        const frac: i64 = if (secs < 0) (2_000_000_000 - @as(i64, nanos)) else (@as(i64, nanos) + 1_000_000_000);
        len += (std.fmt.bufPrint(buf[len..], "{d}", .{frac}) catch unreachable).len;
        while (buf[len - 1] == '0') len -= 1; // strip trailing zeros
        buf[pos] = '.';
    }

    buf[len] = 'S';
    len += 1;
    return buf[0..len];
}

// --- tests ---

const testing = std.testing;

test "Duration value: make / isDuration / accessors + temporal_print set" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const d = try make(&rt, -2, 500_000_000); // ofMillis(-1500) normalized
    try testing.expect(d.tag() == .typed_instance);
    try testing.expect(isDuration(d));
    try testing.expectEqual(@as(i64, -2), secondsOf(d));
    try testing.expectEqual(@as(i32, 500_000_000), nanosOf(d));
    try testing.expect(d.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_duration);
    try testing.expect(!isDuration(Value.initInteger(5)));
}

test "formatDuration: positive / negative / fraction / zero" {
    var buf: [40]u8 = undefined;
    // positive whole, h/m/s decomposition
    try testing.expectEqualStrings("PT1M30S", formatDuration(&buf, 90, 0));
    try testing.expectEqualStrings("PT2H", formatDuration(&buf, 7200, 0));
    try testing.expectEqualStrings("PT1H30M", formatDuration(&buf, 5400, 0));
    try testing.expectEqualStrings("PT1H1M1S", formatDuration(&buf, 3661, 0));
    // zero
    try testing.expectEqualStrings("PT0S", formatDuration(&buf, 0, 0));
    // positive fraction
    try testing.expectEqualStrings("PT1.5S", formatDuration(&buf, 1, 500_000_000));
    try testing.expectEqualStrings("PT0.123456789S", formatDuration(&buf, 0, 123_456_789));
    // negative whole
    try testing.expectEqualStrings("PT-30S", formatDuration(&buf, -30, 0));
    try testing.expectEqualStrings("PT-1H-1M-1S", formatDuration(&buf, -3661, 0));
    // negative with borrowed fraction
    try testing.expectEqualStrings("PT-1.5S", formatDuration(&buf, -2, 500_000_000));
    try testing.expectEqualStrings("PT-0.5S", formatDuration(&buf, -1, 500_000_000));
    // large positive whole (ofDays(1))
    try testing.expectEqualStrings("PT24H", formatDuration(&buf, 86400, 0));
}
