// SPDX-License-Identifier: EPL-2.0
//! `java.time.Instant` namespace-neutral implementation per F-009.
//!
//! Two surfaces consume this file:
//!   1. `runtime/java/time/Instant.zig` — Java 8+ canonical
//!      time class (`(java.time.Instant/now)` /
//!      `(.toEpochMilli inst)`).
//!   2. `runtime/java/util/Date.zig` — legacy `java.util.Date`,
//!      which internally tracks epoch-millis the same way.
//!
//! No Clojure peer at this layer; clojure.instant has its own
//! parser and lives in `lang/clj/clojure/instant.clj`.
//!
//! Zig 0.16 clock surface moved under `std.Io.Clock`; both entry
//! points thread `io: std.Io` (Juicy-Main / Runtime.io).

const std = @import("std");
const clock = @import("../clock.zig");

/// Epoch-millis at the moment of the call. Wall clock. Identical
/// numeric value to `(System/currentTimeMillis)`; the Instant
/// abstraction layers on top of the same wall-clock source.
pub fn nowEpochMillis(io: std.Io) i64 {
    return clock.currentMillis(io);
}

/// Epoch-nanos at the moment of the call. Wall clock too — NOT
/// `clock.nanoTime` (which is monotonic-only without an epoch
/// alignment). For sub-millisecond JVM-Instant compatibility use
/// this; for elapsed-time measurements use `clock.nanoTime`.
pub fn nowEpochNanos(io: std.Io) i128 {
    return std.Io.Clock.real.now(io).toNanoseconds();
}

// --- civil ↔ epoch-ms (D-200 / ADR-0079: #inst / java.util.Date) ---
//
// Pure closed-form conversions (Howard Hinnant's public-domain civil
// algorithms) so `#inst` parse/print needs no OS calendar + no allocation.
// All values are UTC; `java.util.Date` is millisecond precision.

const MS_PER_DAY: i64 = 86_400_000;

/// Days since the Unix epoch (1970-01-01) for a proleptic-Gregorian
/// `(y, m, d)` (m,d 1-based). Hinnant `days_from_civil`.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

/// Inverse of `daysFromCivil`. Hinnant `civil_from_days`.
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe = z - era * 146097; // [0, 146096]
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365); // [0, 399]
    const y = yoe + era * 400;
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100)); // [0, 365]
    const mp = @divTrunc(5 * doy + 2, 153); // [0, 11]
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1; // [1, 31]
    const m = mp + (if (mp < 10) @as(i64, 3) else -9); // [1, 12]
    return .{ .y = y + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
}

const ParseError = error{InvalidInstant};

fn readN(s: []const u8, i: *usize, n: usize) ParseError!i64 {
    if (i.* + n > s.len) return error.InvalidInstant;
    var acc: i64 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = s[i.* + k];
        if (c < '0' or c > '9') return error.InvalidInstant;
        acc = acc * 10 + (c - '0');
    }
    i.* += n;
    return acc;
}

/// Parse a `#inst` RFC3339-subset string → epoch-millis (UTC). Accepts
/// `yyyy`, `yyyy-MM`, `yyyy-MM-dd`, optional `THH:MM[:SS[.fff…]]`, and an
/// optional `Z` / `±HH:MM` offset (absent ⇒ UTC). Mirrors clj
/// `clojure.instant/read-instant-date` for the common grammar.
pub fn parseInstantMillis(s: []const u8) ParseError!i64 {
    var i: usize = 0;
    const year = try readN(s, &i, 4);
    var month: i64 = 1;
    var day: i64 = 1;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var frac_ms: i64 = 0;
    var off_min: i64 = 0;

    if (i < s.len and s[i] == '-') {
        i += 1;
        month = try readN(s, &i, 2);
        if (i < s.len and s[i] == '-') {
            i += 1;
            day = try readN(s, &i, 2);
            if (i < s.len and (s[i] == 'T' or s[i] == ' ')) {
                i += 1;
                hh = try readN(s, &i, 2);
                if (i >= s.len or s[i] != ':') return error.InvalidInstant;
                i += 1;
                mm = try readN(s, &i, 2);
                if (i < s.len and s[i] == ':') {
                    i += 1;
                    ss = try readN(s, &i, 2);
                    if (i < s.len and s[i] == '.') {
                        i += 1;
                        // Fractional seconds: take the first 3 digits as ms,
                        // ignore the rest (java.util.Date is ms precision).
                        var digits: usize = 0;
                        var f: i64 = 0;
                        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                            if (digits < 3) f = f * 10 + (s[i] - '0');
                            digits += 1;
                        }
                        while (digits < 3) : (digits += 1) f *= 10;
                        frac_ms = f;
                    }
                }
                // Optional timezone.
                if (i < s.len) {
                    if (s[i] == 'Z') {
                        i += 1;
                    } else if (s[i] == '+' or s[i] == '-') {
                        const sign: i64 = if (s[i] == '-') -1 else 1;
                        i += 1;
                        const oh = try readN(s, &i, 2);
                        if (i < s.len and s[i] == ':') i += 1;
                        const om = try readN(s, &i, 2);
                        off_min = sign * (oh * 60 + om);
                    }
                }
            }
        }
    }
    if (i != s.len) return error.InvalidInstant;
    if (month < 1 or month > 12 or day < 1 or day > 31 or hh > 23 or mm > 59 or ss > 60) {
        return error.InvalidInstant;
    }

    const days = daysFromCivil(year, month, day);
    const tod_ms = ((hh * 3600 + mm * 60 + ss) * 1000) + frac_ms;
    return days * MS_PER_DAY + tod_ms - off_min * 60 * 1000;
}

/// Format epoch-millis (UTC) → the canonical `#inst` body
/// `YYYY-MM-DDTHH:MM:SS.mmm-00:00` (clj `print-date` form). Writes into
/// `buf` (≥ 29 bytes) and returns the written slice.
pub fn formatInstantMillis(buf: []u8, epoch_ms: i64) []const u8 {
    const day = @divFloor(epoch_ms, MS_PER_DAY);
    var rem = epoch_ms - day * MS_PER_DAY; // [0, MS_PER_DAY)
    const c = civilFromDays(day);
    const ms: i64 = @rem(rem, 1000);
    rem = @divFloor(rem, 1000);
    const sec = @rem(rem, 60);
    rem = @divFloor(rem, 60);
    const min = @rem(rem, 60);
    const hour = @divFloor(rem, 60);
    // Zig's `{d:0>N}` zero-pad emits a `+` sign for SIGNED ints; cast the
    // (always non-negative) civil fields to unsigned so the pad is clean.
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}-00:00", .{
        @as(u64, @intCast(c.y)),  @as(u64, @intCast(c.m)),   @as(u64, @intCast(c.d)),
        @as(u64, @intCast(hour)), @as(u64, @intCast(min)),   @as(u64, @intCast(sec)),
        @as(u64, @intCast(ms)),
    }) catch buf[0..0];
}

// --- tests ---

const testing = std.testing;

test "civil round-trip: epoch day 0 = 1970-01-01" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const c = civilFromDays(0);
    try testing.expectEqual(@as(i64, 1970), c.y);
    try testing.expectEqual(@as(i64, 1), c.m);
    try testing.expectEqual(@as(i64, 1), c.d);
}

test "parse #inst date-only → midnight UTC ms; format round-trips" {
    const ms = try parseInstantMillis("2024-01-01");
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2024-01-01T00:00:00.000-00:00", formatInstantMillis(&buf, ms));
}

test "parse #inst epoch + offset normalisation" {
    try testing.expectEqual(@as(i64, 0), try parseInstantMillis("1970-01-01T00:00:00.000-00:00"));
    try testing.expectEqual(@as(i64, 0), try parseInstantMillis("1970-01-01T00:00:00Z"));
    // +09:00 is 9h ahead → the same wall time is 9h earlier in UTC.
    try testing.expectEqual(@as(i64, -9 * 3600 * 1000), try parseInstantMillis("1970-01-01T00:00:00+09:00"));
    const leap = try parseInstantMillis("2000-02-29T12:00:00.500Z");
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2000-02-29T12:00:00.500-00:00", formatInstantMillis(&buf, leap));
}

test "parse rejects malformed" {
    try testing.expectError(error.InvalidInstant, parseInstantMillis("2024-13-01"));
    try testing.expectError(error.InvalidInstant, parseInstantMillis("not-a-date"));
    try testing.expectError(error.InvalidInstant, parseInstantMillis("2024-01-01T00"));
}

test "nowEpochMillis returns a sensible 2026-era epoch ms" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const ms = nowEpochMillis(th.io());
    try testing.expect(ms > 1_700_000_000_000);
}

test "nowEpochNanos is consistent with nowEpochMillis within a 100ms window" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const ms = nowEpochMillis(th.io());
    const ns = nowEpochNanos(th.io());
    const ns_to_ms: i128 = @divTrunc(ns, std.time.ns_per_ms);
    const diff = if (ns_to_ms >= ms) ns_to_ms - ms else ms - ns_to_ms;
    try testing.expect(diff < 100);
}
