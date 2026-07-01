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
/// `(y, m, d)` (m,d 1-based). Hinnant `days_from_civil`. `pub` so the
/// LocalDateTime value layer (`local_date_time_value.zig`) reuses it.
pub fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @as(i64, if (m <= 2) 1 else 0);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400; // [0, 399]
    const doy = @divTrunc(153 * (m + (if (m > 2) @as(i64, -3) else 9)) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

pub const Civil = struct { y: i64, m: i64, d: i64 };

/// Inverse of `daysFromCivil`. Hinnant `civil_from_days`. `pub` so the
/// LocalDateTime value layer reuses it.
pub fn civilFromDays(z_in: i64) Civil {
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

// --- civil month/year arithmetic (D-462: LocalDate / LocalDateTime calendar) ---
//
// Calendar month/year shift with JVM day-clamping, working on `epoch_day`
// directly. The civil home (this file) owns the math so both LocalDate and
// LocalDateTime value layers share ONE implementation (DRY).

/// Proleptic Gregorian leap-year test. `@mod` keeps it correct for negative years.
pub fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

/// Days in month `m` (1..12) of year `y`, accounting for February leap years.
pub fn lengthOfMonth(y: i64, m: i64) i64 {
    const dim = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2 and isLeap(y)) return 29;
    return dim[@intCast(m - 1)];
}

/// Shift `epoch_day` by `n` calendar months, clamping the day-of-month to the
/// new month's length (e.g. Jan-31 +1mo → Feb-28/29). JVM `plusMonths` semantics.
pub fn addMonthsToEpochDay(epoch_day: i64, n: i64) i64 {
    const c = civilFromDays(epoch_day);
    const months_total = c.y * 12 + (c.m - 1) + n;
    const ny = @divFloor(months_total, 12);
    const nm = @mod(months_total, 12) + 1;
    const nd = @min(c.d, lengthOfMonth(ny, nm));
    return daysFromCivil(ny, nm, nd);
}

/// Shift `epoch_day` by `n` calendar years, clamping the day to the target
/// month's length in the new year (Feb-29 → Feb-28). JVM `plusYears` semantics.
pub fn addYearsToEpochDay(epoch_day: i64, n: i64) i64 {
    const c = civilFromDays(epoch_day);
    const ny = c.y + n;
    const nd = @min(c.d, lengthOfMonth(ny, c.m));
    return daysFromCivil(ny, c.m, nd);
}

/// Whole count of date-based `ChronoUnit` `ord` from epoch-day `ed1` to `ed2`
/// (JVM `LocalDate.until(end, unit)`). Returns null for a non-date unit (time
/// units / ERAS / FOREVER). MONTHS uses proleptic-month*32 + day-of-month
/// packing so day-of-month boundaries round toward zero exactly as the JVM does
/// (Jan31→Mar1 = 1 month). Shared by LocalDate + LocalDateTime `.until`.
pub fn dateUntil(ed1: i64, ed2: i64, ord: u8) ?i64 {
    const c1 = civilFromDays(ed1);
    const c2 = civilFromDays(ed2);
    const packed1: i64 = (c1.y * 12 + c1.m - 1) * 32 + c1.d;
    const packed2: i64 = (c2.y * 12 + c2.m - 1) * 32 + c2.d;
    const months: i64 = @divTrunc(packed2 - packed1, 32);
    return switch (ord) {
        7 => ed2 - ed1, // DAYS
        8 => @divTrunc(ed2 - ed1, 7), // WEEKS
        9 => months, // MONTHS
        10 => @divTrunc(months, 12), // YEARS
        11 => @divTrunc(months, 120), // DECADES
        12 => @divTrunc(months, 1200), // CENTURIES
        13 => @divTrunc(months, 12000), // MILLENNIA
        else => null,
    };
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
    return (try parseInstantFields(s)).epoch_ms;
}

/// The instant decomposed into the data the richer types need beyond Date:
/// `epoch_ms` (UTC ms, offset folded — what Date keeps) + `nanos` (the FULL
/// fractional-second in nanoseconds 0..999_999_999, which Date truncates to
/// ms) + `offset_min` (the parsed ±HH:MM offset, which Date folds away).
/// `parseInstantMillis` is the thin epoch-ms-only wrapper — one grammar SSOT
/// (F-009/F-011). Timestamp uses `nanos`; a future Calendar uses `offset_min`.
pub const InstantFields = struct { epoch_ms: i64, nanos: i32, offset_min: i32 };

pub fn parseInstantFields(s: []const u8) ParseError!InstantFields {
    var i: usize = 0;
    const year = try readN(s, &i, 4);
    var month: i64 = 1;
    var day: i64 = 1;
    var hh: i64 = 0;
    var mm: i64 = 0;
    var ss: i64 = 0;
    var frac_ms: i64 = 0;
    var nanos: i64 = 0;
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
                        // Fractional seconds: accumulate up to 9 digits as `nanos`
                        // (Timestamp precision); `frac_ms` = the first 3 (Date).
                        var digits: usize = 0;
                        var n: i64 = 0;
                        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                            if (digits < 9) n = n * 10 + (s[i] - '0');
                            digits += 1;
                        }
                        while (digits < 9) : (digits += 1) n *= 10;
                        nanos = n;
                        frac_ms = @divFloor(nanos, 1_000_000);
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
    return .{
        .epoch_ms = days * MS_PER_DAY + tod_ms - off_min * 60 * 1000,
        .nanos = @intCast(nanos),
        .offset_min = @intCast(off_min),
    };
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
        @as(u64, @intCast(c.y)),  @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
        @as(u64, @intCast(hour)), @as(u64, @intCast(min)), @as(u64, @intCast(sec)),
        @as(u64, @intCast(ms)),
    }) catch buf[0..0];
}

/// Format epoch-millis (UTC, used to the SECOND) + `nanos` → the canonical
/// `#inst` body with a 9-digit fractional second
/// `YYYY-MM-DDTHH:MM:SS.nnnnnnnnn-00:00` (clj Timestamp print form). The ms
/// part of `epoch_ms` is dropped (the fraction is `nanos`, which carries it).
/// Writes into `buf` (≥ 35 bytes) and returns the written slice.
pub fn formatInstantNanos(buf: []u8, epoch_ms: i64, nanos: i32) []const u8 {
    const day = @divFloor(epoch_ms, MS_PER_DAY);
    var rem = epoch_ms - day * MS_PER_DAY; // [0, MS_PER_DAY)
    const c = civilFromDays(day);
    rem = @divFloor(rem, 1000); // drop ms; `nanos` carries the fraction
    const sec = @rem(rem, 60);
    rem = @divFloor(rem, 60);
    const min = @rem(rem, 60);
    const hour = @divFloor(rem, 60);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>9}-00:00", .{
        @as(u64, @intCast(c.y)),   @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
        @as(u64, @intCast(hour)),  @as(u64, @intCast(min)), @as(u64, @intCast(sec)),
        @as(u64, @intCast(nanos)),
    }) catch buf[0..0];
}

/// Format epoch-millis (UTC, used to the SECOND) + `nanos` → the bare
/// `ISO_INSTANT` string clj's `(str instant)` emits — a VARIABLE-length
/// fractional second + `Z` (NOT the `#inst` fixed-fraction + `-00:00` offset
/// form `formatInstantNanos` writes). The fraction is omitted when `nanos == 0`,
/// 3 digits when it is a whole millisecond, 6 when a whole microsecond, else 9.
/// Writes into `buf` (≥ 30 bytes) and returns the written slice.
pub fn formatIsoInstant(buf: []u8, epoch_ms: i64, nanos: i32) []const u8 {
    const day = @divFloor(epoch_ms, MS_PER_DAY);
    var rem = epoch_ms - day * MS_PER_DAY; // [0, MS_PER_DAY)
    const c = civilFromDays(day);
    rem = @divFloor(rem, 1000); // drop ms; `nanos` carries the fraction
    const sec = @rem(rem, 60);
    rem = @divFloor(rem, 60);
    const min = @rem(rem, 60);
    const hour = @divFloor(rem, 60);
    const head = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(c.y)),  @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
        @as(u64, @intCast(hour)), @as(u64, @intCast(min)), @as(u64, @intCast(sec)),
    }) catch return buf[0..0];
    var len = head.len;
    const n: u32 = @intCast(nanos);
    if (n != 0) {
        // Pick the shortest fraction that loses no precision: ms / us / ns.
        const frac = blk: {
            if (@rem(n, 1_000_000) == 0) break :blk std.fmt.bufPrint(buf[len..], ".{d:0>3}", .{n / 1_000_000});
            if (@rem(n, 1000) == 0) break :blk std.fmt.bufPrint(buf[len..], ".{d:0>6}", .{n / 1000});
            break :blk std.fmt.bufPrint(buf[len..], ".{d:0>9}", .{n});
        } catch return buf[0..0];
        len += frac.len;
    }
    if (len < buf.len) {
        buf[len] = 'Z';
        len += 1;
    }
    return buf[0..len];
}

// --- LocalDate / LocalTime format + parse (D-462) ---
//
// The reusable halves of the LocalDateTime ISO format/parse, factored here
// (the F-009 neutral home all temporal value files import) so LocalDate,
// LocalTime, and LocalDateTime share one grammar SSOT. LocalDateTime's format
// is `formatLocalDate ++ "T" ++ formatLocalTime`; its parser splits on 'T'.

const NANO_PER_HOUR: i64 = 3_600_000_000_000;
const NANO_PER_MINUTE: i64 = 60_000_000_000;
const NANO_PER_SECOND: i64 = 1_000_000_000;

/// Format `epoch_day` (signed days since 1970-01-01) as the ISO local date
/// `yyyy-MM-dd` clj's `(str local-date)` emits (4-digit zero-padded year).
/// `buf` must be ≥ 10 bytes; returns the written slice. Year is assumed
/// [0, 9999]; clj `LocalDate.of(1,1,1)` → `"0001-01-01"`.
pub fn formatLocalDate(buf: []u8, epoch_day: i64) []const u8 {
    const c = civilFromDays(epoch_day);
    // Zig's `{d:0>N}` zero-pad emits a `+` for SIGNED ints; cast the
    // (always non-negative) civil fields to unsigned for a clean pad.
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        @as(u64, @intCast(c.y)), @as(u64, @intCast(c.m)), @as(u64, @intCast(c.d)),
    }) catch buf[0..0];
}

/// Format `nano_of_day` (in [0, 86_400_000_000_000)) as the ISO local time
/// clj's `(str local-time)` emits: `HH:mm`, then `:ss` appended only when the
/// second OR nano part is non-zero, then a VARIABLE-length fraction (3 / 6 / 9
/// digits, shortest lossless) appended only when nano is non-zero. `buf` must
/// be ≥ 18 bytes; returns the written slice.
pub fn formatLocalTime(buf: []u8, nano_of_day: i64) []const u8 {
    const hour = @divTrunc(nano_of_day, NANO_PER_HOUR);
    const minute = @rem(@divTrunc(nano_of_day, NANO_PER_MINUTE), 60);
    const sec = @rem(@divTrunc(nano_of_day, NANO_PER_SECOND), 60);
    const nano: i64 = @rem(nano_of_day, NANO_PER_SECOND);
    const head = std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{
        @as(u64, @intCast(hour)), @as(u64, @intCast(minute)),
    }) catch return buf[0..0];
    var len = head.len;
    if (sec != 0 or nano != 0) {
        const ss = std.fmt.bufPrint(buf[len..], ":{d:0>2}", .{@as(u64, @intCast(sec))}) catch return buf[0..0];
        len += ss.len;
    }
    if (nano != 0) {
        const n: u32 = @intCast(nano);
        // Pick the shortest fraction that loses no precision: ms / us / ns.
        const frac = blk: {
            if (@rem(n, 1_000_000) == 0) break :blk std.fmt.bufPrint(buf[len..], ".{d:0>3}", .{n / 1_000_000});
            if (@rem(n, 1000) == 0) break :blk std.fmt.bufPrint(buf[len..], ".{d:0>6}", .{n / 1000});
            break :blk std.fmt.bufPrint(buf[len..], ".{d:0>9}", .{n});
        } catch return buf[0..0];
        len += frac.len;
    }
    return buf[0..len];
}

/// Parse the ISO local date `yyyy-MM-dd` → `epoch_day` (signed). The year is
/// read as a positive 4-digit field.
pub fn parseLocalDate(s: []const u8) ParseError!i64 {
    var i: usize = 0;
    const y = try readN(s, &i, 4);
    if (i >= s.len or s[i] != '-') return error.InvalidInstant;
    i += 1;
    const m = try readN(s, &i, 2);
    if (i >= s.len or s[i] != '-') return error.InvalidInstant;
    i += 1;
    const d = try readN(s, &i, 2);
    if (i != s.len) return error.InvalidInstant;
    if (m < 1 or m > 12 or d < 1 or d > 31) return error.InvalidInstant;
    return daysFromCivil(y, m, d);
}

/// Parse the ISO local time `HH:mm[:ss[.fraction]]` → `nano_of_day` (the
/// fraction is 1-9 digits scaled to nanos). No offset / `Z`.
pub fn parseLocalTime(s: []const u8) ParseError!i64 {
    var i: usize = 0;
    const h = try readN(s, &i, 2);
    if (i >= s.len or s[i] != ':') return error.InvalidInstant;
    i += 1;
    const mi = try readN(s, &i, 2);
    var sec: i64 = 0;
    var nanos: i64 = 0;
    if (i < s.len and s[i] == ':') {
        i += 1;
        sec = try readN(s, &i, 2);
        if (i < s.len and s[i] == '.') {
            i += 1;
            // Fractional seconds: 1-9 digits scaled to nanos (pad / truncate to 9).
            var digits: usize = 0;
            var acc: i64 = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
                if (digits < 9) acc = acc * 10 + (s[i] - '0');
                digits += 1;
            }
            if (digits == 0) return error.InvalidInstant;
            while (digits < 9) : (digits += 1) acc *= 10;
            nanos = acc;
        }
    }
    if (i != s.len) return error.InvalidInstant;
    if (h > 23 or mi > 59 or sec > 59) return error.InvalidInstant;
    return ((h * 60 + mi) * 60 + sec) * NANO_PER_SECOND + nanos;
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

test "formatIsoInstant: variable-fraction + Z (clj str form)" {
    var buf: [40]u8 = undefined;
    // nanos == 0 → no fraction.
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", formatIsoInstant(&buf, 0, 0));
    // whole millisecond → 3-digit fraction.
    try testing.expectEqualStrings("2024-01-01T00:00:00.500Z", formatIsoInstant(&buf, 1_704_067_200_000, 500_000_000));
    // whole microsecond → 6-digit fraction.
    try testing.expectEqualStrings("1970-01-01T00:00:00.000123Z", formatIsoInstant(&buf, 0, 123_000));
    // sub-microsecond → 9-digit fraction.
    try testing.expectEqualStrings("1970-01-01T00:00:00.123456789Z", formatIsoInstant(&buf, 0, 123_456_789));
}

test "formatLocalDate: 4-digit zero-padded year (clj str form)" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("2024-01-01", formatLocalDate(&buf, daysFromCivil(2024, 1, 1)));
    try testing.expectEqualStrings("2024-12-31", formatLocalDate(&buf, daysFromCivil(2024, 12, 31)));
    try testing.expectEqualStrings("0001-01-01", formatLocalDate(&buf, daysFromCivil(1, 1, 1)));
}

test "formatLocalTime: conditional seconds + variable fraction (clj str form)" {
    var buf: [24]u8 = undefined;
    // HH:mm only — sec == 0 && nano == 0
    try testing.expectEqualStrings("12:30", formatLocalTime(&buf, (12 * 60 + 30) * 60_000_000_000));
    // :ss appended — sec != 0
    try testing.expectEqualStrings("12:30:45", formatLocalTime(&buf, ((12 * 60 + 30) * 60 + 45) * 1_000_000_000));
    // :ss + 3-digit fraction — whole millisecond nano
    try testing.expectEqualStrings("12:30:45.500", formatLocalTime(&buf, ((12 * 60 + 30) * 60 + 45) * 1_000_000_000 + 500_000_000));
    // 9-digit fraction — sub-microsecond nano
    try testing.expectEqualStrings("14:05:45.123456789", formatLocalTime(&buf, ((14 * 60 + 5) * 60 + 45) * 1_000_000_000 + 123_456_789));
    // midnight — both zero, no :ss
    try testing.expectEqualStrings("00:00", formatLocalTime(&buf, 0));
    // nano != 0 but sec == 0 — :00 still appended (sec-or-nano gate), then fraction
    try testing.expectEqualStrings("12:30:00.250", formatLocalTime(&buf, (12 * 60 + 30) * 60_000_000_000 + 250_000_000));
}

test "parseLocalDate / parseLocalTime round-trip + reject malformed" {
    try testing.expectEqual(daysFromCivil(2024, 2, 29), try parseLocalDate("2024-02-29"));
    try testing.expectEqual(@as(i64, 0), try parseLocalDate("1970-01-01"));
    try testing.expectError(error.InvalidInstant, parseLocalDate("2024-13-01"));
    try testing.expectError(error.InvalidInstant, parseLocalDate("not-a-date"));
    try testing.expectError(error.InvalidInstant, parseLocalDate("2024-01-01T00:00"));

    try testing.expectEqual(((6 * 60 + 7) * 60 + 8) * 1_000_000_000, try parseLocalTime("06:07:08"));
    try testing.expectEqual((12 * 60 + 30) * 60_000_000_000, try parseLocalTime("12:30"));
    try testing.expectEqual(((12 * 60 + 30) * 60 + 45) * 1_000_000_000 + 500_000_000, try parseLocalTime("12:30:45.5"));
    try testing.expectError(error.InvalidInstant, parseLocalTime("25:00"));
    try testing.expectError(error.InvalidInstant, parseLocalTime("12"));
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
