// SPDX-License-Identifier: EPL-2.0
//! `java.time.Duration` VALUE (D-462) — a signed time span.
//!
//! Mirrors the Instant model (`instant_value.zig`): a no-slot cljw-native
//! `.typed_instance` (F-004 layout UNCHANGED, no NaN-box tag) carrying TWO
//! integer fields — `seconds` (signed) + `nanos` (0..999_999_999) — NORMALIZED
//! so the nanos fraction is non-negative and the seconds field carries the
//! sign. A per-Runtime `.native` descriptor whose `temporal_print = .iso_duration`
//! makes the printer emit the bare ISO-8601 duration string (`PT…`, NO `#tag`,
//! no quotes — clj's `(str duration)` form). The PT-format itself
//! (`formatDuration`) is self-contained here (no civil calendar). The Java
//! `java.time.Duration` static surface (`runtime/java/time/Duration.zig`) mints
//! these from above.
//!
//! Distinct from Instant/Date/Timestamp by the per-Runtime descriptor pointer
//! (so `=` / print / `(class …)` discriminate) and by carrying the instance
//! methods `.getSeconds` / `.getNano` / `.toMillis` / `.toMinutes`.

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

/// The per-Runtime canonical Duration descriptor (lazily allocated on
/// `gc.infra`; freed in `Runtime.deinit`). `fqcn = "Duration"` so `(class …)`
/// prints the simple name (AD-003 / no-JVM); `temporal_print = .iso_duration`
/// drives the bare `PT…` print form. Carries the instance methods.
pub fn descriptorOf(rt: *Runtime) !*const TypeDescriptor {
    if (rt.duration_descriptor) |d| return d;
    const td = try rt.gc.infra.create(TypeDescriptor);
    td.* = .{
        .fqcn = "Duration",
        .kind = .native,
        .field_layout = null,
        .protocol_impls = &.{},
        .method_table = &.{},
        .parent = null,
        .meta = .nil_val,
        .temporal_print = .iso_duration,
    };
    const specs = .{
        .{ "getSeconds", &getSecondsFn },
        .{ "getNano", &getNanoFn },
        .{ "toMillis", &toMillisFn },
        .{ "toMinutes", &toMinutesFn },
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
    rt.duration_descriptor = td;
    return td;
}

/// Build a Duration from already-NORMALIZED `seconds` (signed) + `nanos`
/// (0..999_999_999). Two typed_instance fields. The factory surface
/// (`Duration.zig`) does the normalization before calling.
pub fn make(rt: *Runtime, seconds: i64, nanos: i32) !Value {
    const td = try descriptorOf(rt);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(seconds), Value.initInteger(nanos) });
}

/// True when `v` is a Duration (carries the per-Runtime Duration descriptor).
pub fn isDuration(rt: *Runtime, v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const d = rt.duration_descriptor orelse return false;
    return v.decodePtr(*const TypedInstance).descriptor == d;
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

/// Free the per-Runtime descriptor (gc.infra-allocated). Called from
/// `Runtime.deinit`; idempotent.
pub fn deinitDescriptor(rt: *Runtime) void {
    if (rt.duration_descriptor) |td| {
        for (td.method_table) |e| rt.gc.infra.free(e.method_name);
        if (td.method_table.len > 0) rt.gc.infra.free(td.method_table);
        rt.gc.infra.destroy(td);
        rt.duration_descriptor = null;
    }
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
    try testing.expect(isDuration(&rt, d));
    try testing.expectEqual(@as(i64, -2), secondsOf(d));
    try testing.expectEqual(@as(i32, 500_000_000), nanosOf(d));
    try testing.expect(d.decodePtr(*const TypedInstance).descriptor.temporal_print == .iso_duration);
    try testing.expect(!isDuration(&rt, Value.initInteger(5)));
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
