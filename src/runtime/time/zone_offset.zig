// SPDX-License-Identifier: EPL-2.0
//! Fixed-offset time zones: `java.time.ZoneOffset` and the offset-backed
//! `java.time.ZoneRegion` ids `UTC` / `GMT` / `UT` (optionally suffixed
//! `UTC+01:00`). The zone a `DateTimeFormatter.withZone` carries and the
//! `ZoneId/of` result.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! cljw ships no time-zone database, so a region id such as `Europe/Paris`
//! is refused (`zone_id_unknown`) instead of resolving to a guessed offset.
//! Every zone that IS representable has one fixed offset, so a zone is two
//! integers: the total offset seconds and the id prefix. A value is a
//! `.typed_instance` carrying exactly those two fields; the prefix selects the
//! class (`.none` = ZoneOffset, otherwise ZoneRegion), so `=` / `hash` by
//! fields + descriptor match the JVM's `ZoneOffset.equals` / `ZoneRegion.equals`
//! (both by id).
//!
//! The parse rules and the DateTimeException texts follow
//! `ZoneOffset.of` / `ZoneOffset.ofHoursMinutesSeconds` / `ZoneId.of`.

const std = @import("std");
const Value = @import("../value/value.zig").Value;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const string_collection = @import("../collection/string.zig");

/// The id prefix of a region zone. `.none` is a bare ZoneOffset.
pub const Prefix = enum(u8) { none = 0, utc = 1, gmt = 2, ut = 3 };

pub const Zone = struct {
    /// Total offset from UTC in seconds, within ±64800 (±18:00).
    seconds: i32,
    prefix: Prefix = .none,

    pub const utc_offset: Zone = .{ .seconds = 0 };

    pub fn isRegion(self: Zone) bool {
        return self.prefix != .none;
    }
};

pub const MAX_SECONDS: i32 = 18 * 3600;

/// A failed parse / validation: the JVM DateTimeException text, or `region`
/// when the id is a well-formed region id the missing tz database would serve.
pub const Diag = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,
    region: bool = false,

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    fn set(self: *Diag, comptime fmt: []const u8, args: anytype) error{Invalid} {
        self.len = if (std.fmt.bufPrint(&self.buf, fmt, args)) |s| s.len else |_| self.buf.len;
        return error.Invalid;
    }
};

/// `ZoneOffset.ofHoursMinutesSeconds` validation + fold to total seconds.
pub fn ofHoursMinutesSeconds(h: i64, m: i64, s: i64, diag: *Diag) error{Invalid}!i32 {
    if (h < -18 or h > 18)
        return diag.set("Zone offset hours not in valid range: value {d} is not in the range -18 to 18", .{h});
    if (h > 0) {
        if (m < 0 or s < 0) return diag.set("Zone offset minutes and seconds must be positive because hours is positive", .{});
    } else if (h < 0) {
        if (m > 0 or s > 0) return diag.set("Zone offset minutes and seconds must be negative because hours is negative", .{});
    } else if ((m > 0 and s < 0) or (m < 0 and s > 0)) {
        return diag.set("Zone offset minutes and seconds must have the same sign", .{});
    }
    if (m < -59 or m > 59)
        return diag.set("Zone offset minutes not in valid range: value {d} is not in the range -59 to 59", .{m});
    if (s < -59 or s > 59)
        return diag.set("Zone offset seconds not in valid range: value {d} is not in the range -59 to 59", .{s});
    if ((h == 18 or h == -18) and (m != 0 or s != 0))
        return diag.set("Zone offset not in valid range: -18:00 to +18:00", .{});
    return @intCast(h * 3600 + m * 60 + s);
}

/// `ZoneOffset.ofTotalSeconds` validation.
pub fn ofTotalSeconds(total: i64, diag: *Diag) error{Invalid}!i32 {
    if (total < -MAX_SECONDS or total > MAX_SECONDS)
        return diag.set("Zone offset not in valid range: -18:00 to +18:00", .{});
    return @intCast(total);
}

fn twoDigits(id: []const u8, pos: usize, preceded_by_colon: bool, diag: *Diag) error{Invalid}!i64 {
    if (preceded_by_colon and id[pos - 1] != ':')
        return diag.set("Invalid ID for ZoneOffset, colon not found when expected: {s}", .{id});
    const a = id[pos];
    const b = id[pos + 1];
    if (a < '0' or a > '9' or b < '0' or b > '9')
        return diag.set("Invalid ID for ZoneOffset, non numeric characters found: {s}", .{id});
    return (a - '0') * 10 + (b - '0');
}

/// `ZoneOffset.of(id)`: `Z`, `+h`, `+hh`, `+hh:mm`, `+hhmm`, `+hh:mm:ss`,
/// `+hhmmss` (and the `-` forms).
pub fn parseOffsetId(id: []const u8, diag: *Diag) error{Invalid}!i32 {
    if (std.mem.eql(u8, id, "Z")) return 0;
    var padded: [3]u8 = undefined;
    var src = id;
    if (id.len == 2) {
        padded = .{ id[0], '0', id[1] };
        src = &padded;
    }
    var h: i64 = 0;
    var m: i64 = 0;
    var s: i64 = 0;
    switch (src.len) {
        3 => h = try twoDigits(src, 1, false, diag),
        5 => {
            h = try twoDigits(src, 1, false, diag);
            m = try twoDigits(src, 3, false, diag);
        },
        6 => {
            h = try twoDigits(src, 1, false, diag);
            m = try twoDigits(src, 4, true, diag);
        },
        7 => {
            h = try twoDigits(src, 1, false, diag);
            m = try twoDigits(src, 3, false, diag);
            s = try twoDigits(src, 5, false, diag);
        },
        9 => {
            h = try twoDigits(src, 1, false, diag);
            m = try twoDigits(src, 4, true, diag);
            s = try twoDigits(src, 7, true, diag);
        },
        else => return diag.set("Invalid ID for ZoneOffset, invalid format: {s}", .{id}),
    }
    const first = src[0];
    if (first != '+' and first != '-')
        return diag.set("Invalid ID for ZoneOffset, plus/minus not found when expected: {s}", .{id});
    return if (first == '-') ofHoursMinutesSeconds(-h, -m, -s, diag) else ofHoursMinutesSeconds(h, m, s, diag);
}

fn isRegionIdChar(c: u8, first: bool) bool {
    if (std.ascii.isAlphabetic(c)) return true;
    if (first) return false;
    return std.ascii.isDigit(c) or c == '~' or c == '/' or c == '.' or c == '_' or c == '+' or c == '-';
}

/// `ZoneId.of(id)`: an offset id, `UTC` / `GMT` / `UT` with an optional
/// `+offset` suffix, or a region id (refused: `diag.region` is set).
pub fn parseZoneId(id: []const u8, diag: *Diag) error{Invalid}!Zone {
    if (id.len <= 1 or id[0] == '+' or id[0] == '-') return .{ .seconds = try parseOffsetId(id, diag) };
    const prefixes = [_]struct { text: []const u8, p: Prefix }{
        .{ .text = "UTC", .p = .utc }, .{ .text = "GMT", .p = .gmt }, .{ .text = "UT", .p = .ut },
    };
    for (prefixes) |pre| {
        if (!std.mem.startsWith(u8, id, pre.text)) continue;
        const rest = id[pre.text.len..];
        if (rest.len == 0) return .{ .seconds = 0, .prefix = pre.p };
        if (rest[0] == '+' or rest[0] == '-') return .{ .seconds = try parseOffsetId(rest, diag), .prefix = pre.p };
    }
    for (id, 0..) |c, i| {
        if (!isRegionIdChar(c, i == 0))
            return diag.set("Invalid ID for region-based ZoneId, invalid format: {s}", .{id});
    }
    diag.region = true;
    return error.Invalid;
}

/// The offset id: `Z`, or `±hh:mm` with `:ss` only when non-zero.
pub fn formatOffsetId(buf: []u8, seconds: i32) []const u8 {
    if (seconds == 0) return std.fmt.bufPrint(buf, "Z", .{}) catch unreachable;
    const abs: u32 = @abs(seconds);
    const sign: u8 = if (seconds < 0) '-' else '+';
    const h = abs / 3600;
    const m = (abs / 60) % 60;
    const s = abs % 60;
    if (s != 0) return std.fmt.bufPrint(buf, "{c}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, h, m, s }) catch unreachable;
    return std.fmt.bufPrint(buf, "{c}{d:0>2}:{d:0>2}", .{ sign, h, m }) catch unreachable;
}

/// The zone id: the offset id for a ZoneOffset; the prefix, then the offset id
/// when non-zero, for a region (`UTC`, `UTC+01:00`).
pub fn formatId(buf: []u8, zone: Zone) []const u8 {
    const prefix: []const u8 = switch (zone.prefix) {
        .none => return formatOffsetId(buf, zone.seconds),
        .utc => "UTC",
        .gmt => "GMT",
        .ut => "UT",
    };
    @memcpy(buf[0..prefix.len], prefix);
    if (zone.seconds == 0) return buf[0..prefix.len];
    const tail = formatOffsetId(buf[prefix.len..], zone.seconds);
    return buf[0 .. prefix.len + tail.len];
}

// --- the Value layer ---

pub const OFFSET_FQCN = "java.time.ZoneOffset";
pub const REGION_FQCN = "java.time.ZoneRegion";
const ZONE_SUPERTYPES = [_][]const u8{"java.time.ZoneId"};

fn getIdFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getId", args, 1, loc);
    var buf: [24]u8 = undefined;
    return string_collection.alloc(rt, formatId(&buf, zoneOf(args[0])));
}

fn getTotalSecondsFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getTotalSeconds", args, 1, loc);
    return Value.initInteger(zoneOf(args[0]).seconds);
}

/// `(.normalized z)` — the ZoneOffset a fixed-offset zone always reduces to.
fn normalizedFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("normalized", args, 1, loc);
    return make(rt, .{ .seconds = zoneOf(args[0]).seconds });
}

/// Register the `Object/toString` the `str` path dispatches plus the shared
/// readers. Sentinel-guarded on `getId` (both registration orders).
fn ensureCommonMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) !void {
    if (td.lookupMethod(null, "getId") != null) return;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getId", &getIdFn },
        .{ "normalized", &normalizedFn },
    });
    try appendObjectToString(td, gpa, &getIdFn);
    td.host_supertypes = &ZONE_SUPERTYPES;
}

/// Append a `toString` entry under the `Object` protocol, the one the
/// `str` path consults for a native `.typed_instance` (`dispatchOrNull`).
pub fn appendObjectToString(td: *TypeDescriptor, gpa: std.mem.Allocator, f: anytype) !void {
    const old = td.method_table;
    const entries = try gpa.alloc(TypeDescriptor.MethodEntry, old.len + 1);
    @memcpy(entries[0..old.len], old);
    entries[old.len] = .{
        .protocol_name = "Object", // borrowed: Runtime.deinit frees method_name only
        .method_name = try gpa.dupe(u8, "toString"),
        .method_val = Value.initBuiltinFn(f),
    };
    if (old.len > 0) gpa.free(old);
    td.method_table = entries;
}

/// ZoneOffset instance methods (also run by the surface `init`).
pub fn ensureOffsetMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    try ensureCommonMethods(td, gpa);
    if (td.lookupMethod(null, "getTotalSeconds") == null)
        try td_mod.appendMethodEntries(td, gpa, .{.{ "getTotalSeconds", &getTotalSecondsFn }});
}

fn configureRegion(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    try ensureCommonMethods(td, gpa);
}

/// Mint the zone Value: a ZoneOffset for `.none`, else a ZoneRegion.
pub fn make(rt: *Runtime, zone: Zone) !Value {
    const td = if (zone.isRegion())
        try td_mod.ensureRegistered(rt, REGION_FQCN, &configureRegion)
    else
        try td_mod.ensureRegistered(rt, OFFSET_FQCN, &ensureOffsetMethods);
    return td_mod.allocInstance(rt, td, &.{ Value.initInteger(zone.seconds), Value.initInteger(@intFromEnum(zone.prefix)) });
}

/// True for a ZoneOffset or a ZoneRegion value.
pub fn isZone(v: Value) bool {
    if (v.tag() != .typed_instance) return false;
    const fq = v.decodePtr(*const TypedInstance).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, OFFSET_FQCN) or std.mem.eql(u8, fq, REGION_FQCN);
}

/// True for a ZoneOffset value only.
pub fn isZoneOffset(v: Value) bool {
    return isZone(v) and zoneOf(v).prefix == .none;
}

/// The zone a value carries. Caller must have checked `isZone`.
pub fn zoneOf(v: Value) Zone {
    const f = v.decodePtr(*const TypedInstance).fields();
    return .{ .seconds = @intCast(f[0].asInteger()), .prefix = @enumFromInt(@as(u8, @intCast(f[1].asInteger()))) };
}

/// Raise the DateTimeException a failed `parseZoneId` / `parseOffsetId`
/// described.
pub fn raiseDiag(diag: *const Diag, id: []const u8, loc: SourceLocation) anyerror {
    if (diag.region) return error_catalog.raise(.zone_id_unknown, loc, .{ .id = id });
    return error_catalog.raise(.date_time_value_invalid, loc, .{ .detail = diag.msg() });
}

// --- tests ---

const testing = std.testing;

test "parseOffsetId: the JVM ZoneOffset.of id forms" {
    var d: Diag = .{};
    try testing.expectEqual(@as(i32, 0), try parseOffsetId("Z", &d));
    try testing.expectEqual(@as(i32, 7200), try parseOffsetId("+2", &d));
    try testing.expectEqual(@as(i32, 7200), try parseOffsetId("+02", &d));
    try testing.expectEqual(@as(i32, -19800), try parseOffsetId("-05:30", &d));
    try testing.expectEqual(@as(i32, -19800), try parseOffsetId("-0530", &d));
    try testing.expectEqual(@as(i32, 3661), try parseOffsetId("+01:01:01", &d));
    try testing.expectError(error.Invalid, parseOffsetId("+25:00", &d));
    try testing.expectEqualStrings("Zone offset hours not in valid range: value 25 is not in the range -18 to 18", d.msg());
    try testing.expectError(error.Invalid, parseOffsetId("+0x:00", &d));
    try testing.expectEqualStrings("Invalid ID for ZoneOffset, non numeric characters found: +0x:00", d.msg());
}

test "parseZoneId: prefixes, offsets, and a refused region" {
    var d: Diag = .{};
    try testing.expectEqual(Zone{ .seconds = 0, .prefix = .utc }, try parseZoneId("UTC", &d));
    try testing.expectEqual(Zone{ .seconds = 3600, .prefix = .utc }, try parseZoneId("UTC+01:00", &d));
    try testing.expectEqual(Zone{ .seconds = 0, .prefix = .ut }, try parseZoneId("UT", &d));
    try testing.expectEqual(Zone{ .seconds = 0 }, try parseZoneId("Z", &d));
    try testing.expectError(error.Invalid, parseZoneId("Europe/Paris", &d));
    try testing.expect(d.region);
}

test "formatId: offset and region ids" {
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("Z", formatId(&buf, .{ .seconds = 0 }));
    try testing.expectEqualStrings("+05:45", formatId(&buf, .{ .seconds = 20700 }));
    try testing.expectEqualStrings("-00:00:30", formatId(&buf, .{ .seconds = -30 }));
    try testing.expectEqualStrings("UTC", formatId(&buf, .{ .seconds = 0, .prefix = .utc }));
    try testing.expectEqualStrings("GMT-03:00", formatId(&buf, .{ .seconds = -10800, .prefix = .gmt }));
}
