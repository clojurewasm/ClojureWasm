// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalDateTime`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_date_time
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic date+time. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalDateTime VALUE (`runtime/time/local_date_time_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getYear /
//! getMonthValue / getDayOfMonth / getHour / getMinute / getSecond / getNano).
//! The civil↔epoch-day conversions are reused from the sibling
//! `runtime/time/instant.zig` (F-009 neutral home).
//!
//! method_table is populated in `initLocalDateTime` (runtime) rather than at
//! module scope because `Value.initBuiltinFn(&fn)` calls `@intFromPtr(&fn)`
//! which is not comptime-known on Mac targets in Zig 0.16.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const instant = @import("../../time/instant.zig");
const ldt_value = @import("../../time/local_date_time_value.zig");
const string_collection = @import("../../collection/string.zig");

const MS_PER_DAY: i64 = 86_400_000;

/// Build the `nano_of_day` from h/mi/s/n (all already validated in range).
fn nanoOfDay(h: i64, mi: i64, s: i64, n: i64) i64 {
    return ((h * 60 + mi) * 60 + s) * 1_000_000_000 + n;
}

/// `(java.time.LocalDateTime/of y m d h mi)` / `(… s)` / `(… s n)` — JVM
/// `LocalDateTime.of`. Arity 5-7: missing second / nano default to 0. All args
/// are integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalDateTime/of", args, 5, 7, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalDateTime/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    const y = args[0].asInteger();
    const m = args[1].asInteger();
    const d = args[2].asInteger();
    const h = args[3].asInteger();
    const mi = args[4].asInteger();
    const s = if (args.len >= 6) args[5].asInteger() else 0;
    const n = if (args.len >= 7) args[6].asInteger() else 0;
    return ldt_value.make(rt, instant.daysFromCivil(y, m, d), nanoOfDay(h, mi, s, n));
}

/// `(java.time.LocalDateTime/now)` — the current wall-clock date-time. cljw has
/// no zone DB, so this is UTC (clj's LocalDateTime.now() is local-zone). The
/// e2e does not assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDateTime/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    const epoch_day = @divFloor(ms, MS_PER_DAY);
    const nano_of_day = @mod(ms, MS_PER_DAY) * 1_000_000;
    return ldt_value.make(rt, epoch_day, nano_of_day);
}

/// `(java.time.LocalDateTime/parse s)` — parse an ISO local date-time
/// `yyyy-MM-ddTHH:mm[:ss[.fraction]]` (NO offset/Z). JVM throws
/// `DateTimeParseException`; cljw raises the same `inst_string_invalid` the
/// `#inst` reader uses.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDateTime/parse", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.LocalDateTime/parse", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const f = parseLocalDateTime(s) catch
        return error_catalog.raise(.inst_string_invalid, loc, .{ .s = s });
    return ldt_value.make(rt, instant.daysFromCivil(f.y, f.m, f.d), nanoOfDay(f.h, f.mi, f.s, f.n));
}

const ParseError = error{Invalid};
const Fields = struct { y: i64, m: i64, d: i64, h: i64, mi: i64, s: i64, n: i64 };

fn readN(s: []const u8, i: *usize, n: usize) ParseError!i64 {
    if (i.* + n > s.len) return error.Invalid;
    var acc: i64 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = s[i.* + k];
        if (c < '0' or c > '9') return error.Invalid;
        acc = acc * 10 + (c - '0');
    }
    i.* += n;
    return acc;
}

/// Parse `yyyy-MM-ddTHH:mm[:ss[.fraction]]` (no offset). The year is read as a
/// positive 4-digit field (the e2e only needs positive years).
fn parseLocalDateTime(s: []const u8) ParseError!Fields {
    var i: usize = 0;
    const y = try readN(s, &i, 4);
    if (i >= s.len or s[i] != '-') return error.Invalid;
    i += 1;
    const m = try readN(s, &i, 2);
    if (i >= s.len or s[i] != '-') return error.Invalid;
    i += 1;
    const d = try readN(s, &i, 2);
    if (i >= s.len or s[i] != 'T') return error.Invalid;
    i += 1;
    const h = try readN(s, &i, 2);
    if (i >= s.len or s[i] != ':') return error.Invalid;
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
            if (digits == 0) return error.Invalid;
            while (digits < 9) : (digits += 1) acc *= 10;
            nanos = acc;
        }
    }
    if (i != s.len) return error.Invalid;
    if (m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or sec > 59) return error.Invalid;
    return .{ .y = y, .m = m, .d = d, .h = h, .mi = mi, .s = sec, .n = nanos };
}

fn initLocalDateTime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalDateTime values point at it). Sentinel-guarded appends
    // keep both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
        });
    }
    td.temporal_print = .iso_local_date_time;
    try ldt_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalDateTime",
    .descriptor = &descriptor,
    .init = &initLocalDateTime,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = ldt_value.FQCN, // "java.time.LocalDateTime" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_date_time,
};

// --- tests ---

const testing = std.testing;

test "parseLocalDateTime: with / without seconds + fraction" {
    const a = try parseLocalDateTime("2024-01-01T12:30");
    try testing.expectEqual(@as(i64, 2024), a.y);
    try testing.expectEqual(@as(i64, 30), a.mi);
    try testing.expectEqual(@as(i64, 0), a.s);
    try testing.expectEqual(@as(i64, 0), a.n);
    const b = try parseLocalDateTime("2024-01-01T12:30:45");
    try testing.expectEqual(@as(i64, 45), b.s);
    const c = try parseLocalDateTime("2024-01-01T12:30:45.5");
    try testing.expectEqual(@as(i64, 500_000_000), c.n);
    try testing.expectError(error.Invalid, parseLocalDateTime("2024-01-01"));
    try testing.expectError(error.Invalid, parseLocalDateTime("not-a-date"));
    try testing.expectError(error.Invalid, parseLocalDateTime("2024-13-01T00:00"));
}
