// SPDX-License-Identifier: EPL-2.0
//! The `java.time.format` engine: a DateTimeFormatter is a tree of printer-
//! parser ops (`Op`), built by `Builder` (directly, or from a pattern string),
//! that formats a `Temporal` view into text and parses text into a field set
//! that `resolve` turns into a date / time / instant.
//!
//! Backend: impl-only
//! Impl deps: instant, zone_offset, host_enum
//! Clojure peer: none
//!
//! Never touches a Runtime (it borrows only the pure `Zone` arithmetic of
//! `zone_offset.zig` and the ChronoField names of the neutral `host_enum`
//! registry): the Value layer (`date_time_formatter_value.zig`) wraps a
//! `Program` / `Builder` in a host instance and maps a `Diag` onto the error
//! catalog. Behaviour follows the JDK 25 `DateTimeFormatterBuilder` printer-
//! parsers one to one (op set, adjacent value parsing, optional sections, the
//! SMART / STRICT resolver, the toString forms), with English text (cljw's only
//! locale). What is left out is refused loudly, never approximated: week-based
//! and quarter fields, localized zone names, padding, the LENIENT resolver.

const std = @import("std");
const Allocator = std.mem.Allocator;
const instant = @import("instant.zig");
const zone_offset = @import("zone_offset.zig");
const Zone = zone_offset.Zone;
const host_enum = @import("../host_enum.zig");

// --- fields ---

/// `java.time.temporal.ChronoField`, in JVM ordinal order (pinned against the
/// host-enum registry below).
pub const Field = enum(u8) {
    nano_of_second,
    nano_of_day,
    micro_of_second,
    micro_of_day,
    milli_of_second,
    milli_of_day,
    second_of_minute,
    second_of_day,
    minute_of_hour,
    minute_of_day,
    hour_of_ampm,
    clock_hour_of_ampm,
    hour_of_day,
    clock_hour_of_day,
    ampm_of_day,
    day_of_week,
    aligned_day_of_week_in_month,
    aligned_day_of_week_in_year,
    day_of_month,
    day_of_year,
    epoch_day,
    aligned_week_of_month,
    aligned_week_of_year,
    month_of_year,
    proleptic_month,
    year_of_era,
    year,
    era,
    instant_seconds,
    offset_seconds,

    /// The display name ("HourOfDay") every message and toString uses.
    pub fn display(self: Field) []const u8 {
        return host_enum.toStringOf(.chrono_field, @intFromEnum(self));
    }

    pub fn isTimeBased(self: Field) bool {
        return @intFromEnum(self) <= @intFromEnum(Field.ampm_of_day);
    }

    pub fn isDateBased(self: Field) bool {
        return @intFromEnum(self) >= @intFromEnum(Field.day_of_week) and @intFromEnum(self) <= @intFromEnum(Field.era);
    }
};

pub const FIELD_COUNT = @typeInfo(Field).@"enum".fields.len;

comptime {
    @setEvalBranchQuota(20_000);
    std.debug.assert(FIELD_COUNT == host_enum.count(.chrono_field));
    for (@typeInfo(Field).@"enum".fields, 0..) |f, i| {
        var upper: [f.name.len]u8 = undefined;
        for (f.name, 0..) |c, j| upper[j] = std.ascii.toUpper(c);
        if (!std.mem.eql(u8, &upper, host_enum.name(.chrono_field, i)))
            @compileError("Field order drifted from the ChronoField registry at " ++ f.name);
    }
}

/// A `ValueRange`: `min - max`, with the smallest maximum for the month- and
/// year-length dependent fields ("1 - 28/31").
const Range = struct {
    min: i64,
    max: i64,
    smallest_max: ?i64 = null,

    fn isValid(self: Range, v: i64) bool {
        return v >= self.min and v <= self.max;
    }
};

const YEAR_MAX: i64 = 999_999_999;

fn rangeOf(f: Field) Range {
    return switch (f) {
        .nano_of_second => .{ .min = 0, .max = 999_999_999 },
        .nano_of_day => .{ .min = 0, .max = 86_400 * 1_000_000_000 - 1 },
        .micro_of_second => .{ .min = 0, .max = 999_999 },
        .micro_of_day => .{ .min = 0, .max = 86_400 * 1_000_000 - 1 },
        .milli_of_second => .{ .min = 0, .max = 999 },
        .milli_of_day => .{ .min = 0, .max = 86_400 * 1000 - 1 },
        .second_of_minute => .{ .min = 0, .max = 59 },
        .second_of_day => .{ .min = 0, .max = 86_400 - 1 },
        .minute_of_hour => .{ .min = 0, .max = 59 },
        .minute_of_day => .{ .min = 0, .max = 24 * 60 - 1 },
        .hour_of_ampm => .{ .min = 0, .max = 11 },
        .clock_hour_of_ampm => .{ .min = 1, .max = 12 },
        .hour_of_day => .{ .min = 0, .max = 23 },
        .clock_hour_of_day => .{ .min = 1, .max = 24 },
        .ampm_of_day => .{ .min = 0, .max = 1 },
        .day_of_week, .aligned_day_of_week_in_month, .aligned_day_of_week_in_year => .{ .min = 1, .max = 7 },
        .day_of_month => .{ .min = 1, .max = 31, .smallest_max = 28 },
        .day_of_year => .{ .min = 1, .max = 366, .smallest_max = 365 },
        .epoch_day => .{ .min = -365_243_219_162, .max = 365_241_780_471 },
        .aligned_week_of_month => .{ .min = 1, .max = 5, .smallest_max = 4 },
        .aligned_week_of_year => .{ .min = 1, .max = 53 },
        .month_of_year => .{ .min = 1, .max = 12 },
        .proleptic_month => .{ .min = -YEAR_MAX * 12, .max = YEAR_MAX * 12 + 11 },
        .year_of_era => .{ .min = 1, .max = YEAR_MAX + 1, .smallest_max = YEAR_MAX },
        .year => .{ .min = -YEAR_MAX, .max = YEAR_MAX },
        .era => .{ .min = 0, .max = 1 },
        .instant_seconds => .{ .min = std.math.minInt(i64), .max = std.math.maxInt(i64) },
        .offset_seconds => .{ .min = -18 * 3600, .max = 18 * 3600 },
    };
}

// --- diagnostics ---

/// Why an engine call failed. The Value layer maps each kind to its catalog
/// code (and so its JVM exception class).
pub const Diag = struct {
    kind: Kind = .value,
    field: Field = .year,
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub const Kind = enum {
        /// DateTimeException with `msg()`.
        value,
        /// UnsupportedTemporalTypeException for `field`.
        unsupported_field,
        /// IllegalArgumentException with `msg()` (a malformed pattern / builder call).
        pattern,
        /// A JVM pattern letter cljw does not implement; `msg()` is the letter.
        pattern_letter,
        /// IllegalStateException with `msg()` (builder misuse).
        state,
    };

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn fail(self: *Diag, kind: Kind, comptime fmt: []const u8, args: anytype) error{DateTime} {
        self.kind = kind;
        self.len = if (std.fmt.bufPrint(&self.buf, fmt, args)) |s| s.len else |_| self.buf.len;
        return error.DateTime;
    }

    fn unsupported(self: *Diag, f: Field) error{DateTime} {
        self.field = f;
        return self.fail(.unsupported_field, "Unsupported field: {s}", .{f.display()});
    }

    /// `ChronoField.checkValidValue`'s "Invalid value for X (valid values …): v".
    fn invalidValue(self: *Diag, f: Field, v: i64) error{DateTime} {
        const r = rangeOf(f);
        var rb: [64]u8 = undefined;
        const rs = if (r.smallest_max) |sm|
            std.fmt.bufPrint(&rb, "{d} - {d}/{d}", .{ r.min, sm, r.max }) catch unreachable
        else
            std.fmt.bufPrint(&rb, "{d} - {d}", .{ r.min, r.max }) catch unreachable;
        return self.fail(.value, "Invalid value for {s} (valid values {s}): {d}", .{ f.display(), rs, v });
    }
};

pub const Error = error{ DateTime, OutOfMemory };

fn checkValid(f: Field, v: i64, diag: *Diag) error{DateTime}!i64 {
    if (!rangeOf(f).isValid(v)) return diag.invalidValue(f, v);
    return v;
}

// --- the field set a parse fills ---

pub const FieldSet = struct {
    vals: [FIELD_COUNT]i64 = @splat(0),
    mask: u32 = 0,

    pub fn has(self: *const FieldSet, f: Field) bool {
        return self.mask & bit(f) != 0;
    }

    pub fn get(self: *const FieldSet, f: Field) ?i64 {
        return if (self.has(f)) self.vals[@intFromEnum(f)] else null;
    }

    /// Store, returning the previous value.
    pub fn put(self: *FieldSet, f: Field, v: i64) ?i64 {
        const old = self.get(f);
        self.vals[@intFromEnum(f)] = v;
        self.mask |= bit(f);
        return old;
    }

    pub fn remove(self: *FieldSet, f: Field) ?i64 {
        const old = self.get(f);
        self.mask &= ~bit(f);
        return old;
    }

    pub fn isEmpty(self: *const FieldSet) bool {
        return self.mask == 0;
    }

    fn bit(f: Field) u32 {
        return @as(u32, 1) << @intCast(@intFromEnum(f));
    }
};

// --- the temporal view a formatter reads ---

/// What a TemporalAccessor exposes to the printer: a date (epoch day), a time
/// (nano of day), an offset, a zone, an instant, and (for a parse result) the
/// leftover field set, consulted first like `Parsed.getLong`.
pub const Temporal = struct {
    date: ?i64 = null,
    time: ?i64 = null,
    offset: ?i32 = null,
    zone: ?Zone = null,
    instant_secs: ?i64 = null,
    instant_nanos: i32 = 0,
    fields: ?*const FieldSet = null,

    /// The ISO view of an instant at a fixed offset (a ZonedDateTime).
    pub fn atZone(secs: i64, nanos: i32, zone: Zone) Temporal {
        const local = secs + zone.seconds;
        return .{
            .date = @divFloor(local, 86_400),
            .time = @mod(local, 86_400) * 1_000_000_000 + nanos,
            .offset = zone.seconds,
            .zone = zone,
            .instant_secs = secs,
            .instant_nanos = nanos,
        };
    }

    pub fn getField(self: *const Temporal, f: Field) ?i64 {
        if (self.fields) |fs| {
            if (fs.get(f)) |v| return v;
        }
        if (f.isDateBased() or f == .epoch_day) {
            const ed = self.date orelse return null;
            return dateField(ed, f);
        }
        if (f.isTimeBased()) {
            if (self.time) |nod| return timeField(nod, f);
            if (self.fields == null and self.instant_secs != null) {
                const n: i64 = self.instant_nanos;
                return switch (f) {
                    .nano_of_second => n,
                    .micro_of_second => @divFloor(n, 1000),
                    .milli_of_second => @divFloor(n, 1_000_000),
                    else => null,
                };
            }
            return null;
        }
        if (self.fields != null) return null; // a Parsed derives nothing else
        return switch (f) {
            .offset_seconds => if (self.offset) |o| @as(i64, o) else null,
            .instant_seconds => self.instant_secs,
            else => unreachable,
        };
    }
};

fn dateField(ed: i64, f: Field) i64 {
    const c = instant.civilFromDays(ed);
    const doy = ed - instant.daysFromCivil(c.y, 1, 1) + 1;
    return switch (f) {
        .day_of_week => @mod(ed + 3, 7) + 1,
        .aligned_day_of_week_in_month => @mod(c.d - 1, 7) + 1,
        .aligned_day_of_week_in_year => @mod(doy - 1, 7) + 1,
        .day_of_month => c.d,
        .day_of_year => doy,
        .epoch_day => ed,
        .aligned_week_of_month => @divFloor(c.d - 1, 7) + 1,
        .aligned_week_of_year => @divFloor(doy - 1, 7) + 1,
        .month_of_year => c.m,
        .proleptic_month => c.y * 12 + c.m - 1,
        .year_of_era => if (c.y >= 1) c.y else 1 - c.y,
        .year => c.y,
        .era => if (c.y >= 1) 1 else 0,
        else => unreachable,
    };
}

fn timeField(nod: i64, f: Field) i64 {
    const hod = @divFloor(nod, 3_600_000_000_000);
    return switch (f) {
        .nano_of_second => @mod(nod, 1_000_000_000),
        .nano_of_day => nod,
        .micro_of_second => @divFloor(@mod(nod, 1_000_000_000), 1000),
        .micro_of_day => @divFloor(nod, 1000),
        .milli_of_second => @divFloor(@mod(nod, 1_000_000_000), 1_000_000),
        .milli_of_day => @divFloor(nod, 1_000_000),
        .second_of_minute => @mod(@divFloor(nod, 1_000_000_000), 60),
        .second_of_day => @divFloor(nod, 1_000_000_000),
        .minute_of_hour => @mod(@divFloor(nod, 60_000_000_000), 60),
        .minute_of_day => @divFloor(nod, 60_000_000_000),
        .hour_of_ampm => @mod(hod, 12),
        .clock_hour_of_ampm => if (@mod(hod, 12) == 0) 12 else @mod(hod, 12),
        .hour_of_day => hod,
        .clock_hour_of_day => if (hod == 0) 24 else hod,
        .ampm_of_day => @divFloor(hod, 12),
        else => unreachable,
    };
}

// --- the op tree ---

/// `SignStyle`, JVM declaration order.
pub const SignStyle = enum(u8) {
    normal,
    always,
    never,
    not_negative,
    exceeds_pad,

    fn upper(self: SignStyle) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .always => "ALWAYS",
            .never => "NEVER",
            .not_negative => "NOT_NEGATIVE",
            .exceeds_pad => "EXCEEDS_PAD",
        };
    }

    /// `SignStyle.parse(positive, strict, fixedWidth)`: may this sign appear?
    fn allows(self: SignStyle, positive: bool, strict: bool, fixed_width: bool) bool {
        return switch (self) {
            .normal => !positive or !strict,
            .always, .exceeds_pad => true,
            .never, .not_negative => !strict and !fixed_width,
        };
    }
};

pub const TextStyle = enum(u8) {
    full,
    full_standalone,
    short,
    short_standalone,
    narrow,
    narrow_standalone,

    fn upper(self: TextStyle) []const u8 {
        return switch (self) {
            .full => "FULL",
            .full_standalone => "FULL_STANDALONE",
            .short => "SHORT",
            .short_standalone => "SHORT_STANDALONE",
            .narrow => "NARROW",
            .narrow_standalone => "NARROW_STANDALONE",
        };
    }

    fn base(self: TextStyle) TextStyle {
        return switch (self) {
            .full, .full_standalone => .full,
            .short, .short_standalone => .short,
            .narrow, .narrow_standalone => .narrow,
        };
    }
};

pub const ResolverStyle = enum(u8) { strict, smart };

/// The offset patterns `appendOffset` accepts, indexed like the JVM
/// `OffsetIdPrinterParser.PATTERNS` (the padded-hour half).
pub const OFFSET_PATTERNS = [_][]const u8{ "+HH", "+HHmm", "+HH:mm", "+HHMM", "+HH:MM", "+HHMMss", "+HH:MM:ss", "+HHMMSS", "+HH:MM:SS", "+HHmmss", "+HH:mm:ss" };

pub const ValueOp = struct {
    field: Field,
    min: u8,
    max: u8,
    sign: SignStyle,
    /// -1 = fixed width (an adjacent follower); >0 = digits reserved for the
    /// fixed-width values that follow; 0 = neither.
    subsequent: i16 = 0,
    /// A ReducedValue (`yy`): the two-digit window starting at `base`.
    reduced_base: ?i64 = null,
};

pub const FractionOp = struct {
    field: Field,
    min: u8,
    max: u8,
    decimal_point: bool,
};

pub const Op = union(enum) {
    value: ValueOp,
    fraction: FractionOp,
    text: struct { field: Field, style: TextStyle },
    literal: []const u8,
    offset: struct { pattern: u8, no_offset_text: []const u8 },
    localized_offset: TextStyle,
    zone_id,
    zone_region_id,
    instant,
    case_sensitive: bool,
    strict: bool,
    default_value: struct { field: Field, value: i64 },
    composite: struct { ops: []const Op, optional: bool },
};

/// A finished formatter: the root op list plus its resolver style and zone.
pub const Program = struct {
    ops: []const Op,
    resolver: ResolverStyle = .smart,
    zone: ?Zone = null,

    /// Deep copy onto `gpa` (literal text and nested op lists included).
    pub fn clone(self: *const Program, gpa: Allocator) Allocator.Error!*Program {
        const p = try gpa.create(Program);
        errdefer gpa.destroy(p);
        p.* = .{ .ops = try cloneOps(gpa, self.ops), .resolver = self.resolver, .zone = self.zone };
        return p;
    }

    pub fn destroy(self: *Program, gpa: Allocator) void {
        freeOps(gpa, self.ops);
        gpa.destroy(self);
    }
};

fn cloneOp(gpa: Allocator, op: Op) Allocator.Error!Op {
    return switch (op) {
        .literal => |s| .{ .literal = try gpa.dupe(u8, s) },
        .offset => |o| .{ .offset = .{ .pattern = o.pattern, .no_offset_text = try gpa.dupe(u8, o.no_offset_text) } },
        .composite => |c| .{ .composite = .{ .ops = try cloneOps(gpa, c.ops), .optional = c.optional } },
        else => op,
    };
}

fn cloneOps(gpa: Allocator, ops: []const Op) Allocator.Error![]const Op {
    const out = try gpa.alloc(Op, ops.len);
    var done: usize = 0;
    errdefer {
        freeOps(gpa, out[0..done]);
        gpa.free(out[done..]);
    }
    for (ops, 0..) |op, i| {
        out[i] = try cloneOp(gpa, op);
        done = i + 1;
    }
    return out;
}

fn freeOp(gpa: Allocator, op: Op) void {
    switch (op) {
        .literal => |s| gpa.free(s),
        .offset => |o| gpa.free(o.no_offset_text),
        .composite => |c| freeOps(gpa, c.ops),
        else => {},
    }
}

fn freeOps(gpa: Allocator, ops: []const Op) void {
    for (ops) |op| freeOp(gpa, op);
    gpa.free(ops);
}

// --- the builder ---

/// `DateTimeFormatterBuilder`: a stack of levels (the root, then one per open
/// `optionalStart`), each tracking the active adjacent value parser.
pub const Builder = struct {
    levels: std.ArrayList(Level) = .empty,

    const Level = struct {
        ops: std.ArrayList(Op) = .empty,
        optional: bool,
        value_parser: ?usize = null,
    };

    pub fn create(gpa: Allocator) Allocator.Error!*Builder {
        const b = try gpa.create(Builder);
        b.* = .{};
        errdefer gpa.destroy(b);
        try b.levels.append(gpa, .{ .optional = false });
        return b;
    }

    pub fn destroy(self: *Builder, gpa: Allocator) void {
        for (self.levels.items) |*lv| {
            for (lv.ops.items) |op| freeOp(gpa, op);
            lv.ops.deinit(gpa);
        }
        self.levels.deinit(gpa);
        gpa.destroy(self);
    }

    fn active(self: *Builder) *Level {
        return &self.levels.items[self.levels.items.len - 1];
    }

    /// `appendInternal`: append an owned op, ending adjacent value parsing.
    fn appendOwned(self: *Builder, gpa: Allocator, op: Op) Allocator.Error!usize {
        const lv = self.active();
        lv.ops.append(gpa, op) catch |e| {
            freeOp(gpa, op);
            return e;
        };
        lv.value_parser = null;
        return lv.ops.items.len - 1;
    }

    /// Append a copy of `op` (its text and nested ops are duplicated).
    pub fn append(self: *Builder, gpa: Allocator, op: Op) Allocator.Error!void {
        _ = try self.appendOwned(gpa, try cloneOp(gpa, op));
    }

    /// `appendValue(NumberPrinterParser)` with adjacent value parsing: a
    /// fixed-width NOT_NEGATIVE value after an active one reserves its width
    /// in that parser; anything else fixes the active one and takes over.
    fn appendValueOp(self: *Builder, gpa: Allocator, v: ValueOp) Allocator.Error!void {
        const lv = self.active();
        if (lv.value_parser) |base_idx| {
            const base = &lv.ops.items[base_idx];
            const follower_fixed = v.min == v.max and v.sign == .not_negative;
            if (follower_fixed) {
                switch (base.*) {
                    .value => |*bv| bv.subsequent = if (bv.subsequent == -1) -1 else bv.subsequent + v.max,
                    else => {},
                }
                var fixed = v;
                fixed.subsequent = -1;
                _ = try self.appendOwned(gpa, .{ .value = fixed });
                self.active().value_parser = base_idx;
            } else {
                switch (base.*) {
                    .value => |*bv| bv.subsequent = -1,
                    else => {},
                }
                const idx = try self.appendOwned(gpa, .{ .value = v });
                self.active().value_parser = idx;
            }
        } else {
            const idx = try self.appendOwned(gpa, .{ .value = v });
            self.active().value_parser = idx;
        }
    }

    /// `appendValue(field)`: 1 to 19 digits, NORMAL sign.
    pub fn appendValue(self: *Builder, gpa: Allocator, field: Field) Allocator.Error!void {
        try self.appendValueOp(gpa, .{ .field = field, .min = 1, .max = 19, .sign = .normal });
    }

    /// `appendValue(field, width)`: exactly `width` digits, NOT_NEGATIVE.
    pub fn appendValueWidth(self: *Builder, gpa: Allocator, field: Field, width: i64, diag: *Diag) Error!void {
        if (width < 1 or width > 19)
            return diag.fail(.pattern, "The width must be from 1 to 19 inclusive but was {d}", .{width});
        try self.appendValueOp(gpa, .{ .field = field, .min = @intCast(width), .max = @intCast(width), .sign = .not_negative });
    }

    /// `appendValue(field, min, max, signStyle)`.
    pub fn appendValueRange(self: *Builder, gpa: Allocator, field: Field, min: i64, max: i64, sign: SignStyle, diag: *Diag) Error!void {
        if (min == max and sign == .not_negative) return self.appendValueWidth(gpa, field, max, diag);
        if (min < 1 or min > 19)
            return diag.fail(.pattern, "The minimum width must be from 1 to 19 inclusive but was {d}", .{min});
        if (max < 1 or max > 19)
            return diag.fail(.pattern, "The maximum width must be from 1 to 19 inclusive but was {d}", .{max});
        if (max < min)
            return diag.fail(.pattern, "The maximum width must exceed or equal the minimum width but {d} < {d}", .{ max, min });
        try self.appendValueOp(gpa, .{ .field = field, .min = @intCast(min), .max = @intCast(max), .sign = sign });
    }

    /// `appendValueReduced(field, 2, 2, LocalDate.of(2000, 1, 1))` (`yy` / `uu`).
    fn appendValueReduced(self: *Builder, gpa: Allocator, field: Field) Allocator.Error!void {
        try self.appendValueOp(gpa, .{ .field = field, .min = 2, .max = 2, .sign = .not_negative, .reduced_base = 2000 });
    }

    /// `appendFraction(field, min, max, decimalPoint)`.
    pub fn appendFraction(self: *Builder, gpa: Allocator, field: Field, min: i64, max: i64, decimal_point: bool, diag: *Diag) Error!void {
        const r = rangeOf(field);
        if (r.min != 0 or !isPowerOfTen(r.max + 1))
            return diag.fail(.pattern, "Field must have a fixed set of values: {s}", .{field.display()});
        if (min < 0 or min > 9)
            return diag.fail(.pattern, "Minimum width must be from 0 to 9 inclusive but was {d}", .{min});
        if (max < 1 or max > 9)
            return diag.fail(.pattern, "Maximum width must be from 1 to 9 inclusive but was {d}", .{max});
        if (max < min)
            return diag.fail(.pattern, "Maximum width must exceed or equal the minimum width but {d} < {d}", .{ max, min });
        const op: Op = .{ .fraction = .{ .field = field, .min = @intCast(min), .max = @intCast(max), .decimal_point = decimal_point } };
        // A fixed-width fraction without a decimal point joins adjacent value
        // parsing as a follower (`yyyyMMddHHmmssSSS`): the active value parser
        // reserves its width. It never becomes the active parser itself.
        const lv = self.active();
        if (min == max and !decimal_point) {
            if (lv.value_parser) |base_idx| {
                switch (lv.ops.items[base_idx]) {
                    .value => |*bv| if (bv.subsequent != -1) {
                        bv.subsequent += @intCast(max);
                    },
                    else => {},
                }
                _ = try self.appendOwned(gpa, op);
                self.active().value_parser = base_idx;
                return;
            }
        }
        _ = try self.appendOwned(gpa, op);
    }

    pub fn appendText(self: *Builder, gpa: Allocator, field: Field, style: TextStyle) Allocator.Error!void {
        _ = try self.appendOwned(gpa, .{ .text = .{ .field = field, .style = style } });
    }

    /// `appendLiteral`: an empty string appends nothing.
    pub fn appendLiteral(self: *Builder, gpa: Allocator, s: []const u8) Allocator.Error!void {
        if (s.len == 0) return;
        _ = try self.appendOwned(gpa, .{ .literal = try gpa.dupe(u8, s) });
    }

    pub fn appendOffset(self: *Builder, gpa: Allocator, pattern: []const u8, no_offset_text: []const u8, diag: *Diag) Error!void {
        for (OFFSET_PATTERNS, 0..) |p, i| {
            if (std.mem.eql(u8, p, pattern)) {
                _ = try self.appendOwned(gpa, .{ .offset = .{ .pattern = @intCast(i), .no_offset_text = try gpa.dupe(u8, no_offset_text) } });
                return;
            }
        }
        if (pattern.len >= 2 and pattern[0] == '+' and pattern[1] == 'H' and (pattern.len == 2 or pattern[2] != 'H'))
            return diag.fail(.pattern_letter, "{s}", .{pattern});
        return diag.fail(.pattern, "Invalid zone offset pattern: {s}", .{pattern});
    }

    pub fn appendLocalizedOffset(self: *Builder, gpa: Allocator, style: TextStyle, diag: *Diag) Error!void {
        if (style != .full and style != .short)
            return diag.fail(.pattern, "Style must be either full or short", .{});
        _ = try self.appendOwned(gpa, .{ .localized_offset = style });
    }

    /// `optionalStart`: open a nested optional level.
    pub fn optionalStart(self: *Builder, gpa: Allocator) Allocator.Error!void {
        self.active().value_parser = null;
        try self.levels.append(gpa, .{ .optional = true });
    }

    /// `optionalEnd`: close the innermost optional level into its parent.
    pub fn optionalEnd(self: *Builder, gpa: Allocator, diag: *Diag) Error!void {
        if (self.levels.items.len <= 1)
            return diag.fail(.state, "Cannot call optionalEnd() as there was no previous call to optionalStart()", .{});
        var lv = self.levels.pop().?;
        if (lv.ops.items.len == 0) {
            lv.ops.deinit(gpa);
            return;
        }
        const ops = lv.ops.toOwnedSlice(gpa) catch |e| {
            for (lv.ops.items) |op| freeOp(gpa, op);
            lv.ops.deinit(gpa);
            return e;
        };
        _ = try self.appendOwned(gpa, .{ .composite = .{ .ops = ops, .optional = lv.optional } });
    }

    /// `append(formatter)` / `appendOptional(formatter)`.
    pub fn appendProgram(self: *Builder, gpa: Allocator, p: *const Program, optional: bool) Allocator.Error!void {
        _ = try self.appendOwned(gpa, .{ .composite = .{ .ops = try cloneOps(gpa, p.ops), .optional = optional } });
    }

    /// `toFormatter`: close every open optional level, copy the root.
    pub fn toProgram(self: *Builder, gpa: Allocator, resolver: ResolverStyle) Error!*Program {
        var diag: Diag = .{};
        while (self.levels.items.len > 1) self.optionalEnd(gpa, &diag) catch |e| switch (e) {
            error.DateTime => unreachable,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const root: Program = .{ .ops = self.levels.items[0].ops.items, .resolver = resolver };
        return root.clone(gpa);
    }

    /// `appendPattern`: compile a pattern string into this builder.
    pub fn appendPattern(self: *Builder, gpa: Allocator, pattern: []const u8, diag: *Diag) Error!void {
        var pos: usize = 0;
        while (pos < pattern.len) : (pos += 1) {
            const cur = pattern[pos];
            if (std.ascii.isAlphabetic(cur)) {
                const start = pos;
                while (pos + 1 < pattern.len and pattern[pos + 1] == cur) pos += 1;
                const count = pos - start + 1;
                try self.patternLetter(gpa, cur, count, diag);
            } else if (cur == '\'') {
                const start = pos;
                pos += 1;
                while (pos < pattern.len) : (pos += 1) {
                    if (pattern[pos] == '\'') {
                        if (pos + 1 < pattern.len and pattern[pos + 1] == '\'') {
                            pos += 1;
                        } else break;
                    }
                }
                if (pos >= pattern.len)
                    return diag.fail(.pattern, "Pattern ends with an incomplete string literal: {s}", .{pattern});
                const raw = pattern[start + 1 .. pos];
                if (raw.len == 0) {
                    try self.appendLiteral(gpa, "'");
                } else {
                    const unq = try std.mem.replaceOwned(u8, gpa, raw, "''", "'");
                    defer gpa.free(unq);
                    try self.appendLiteral(gpa, unq);
                }
            } else if (cur == '[') {
                try self.optionalStart(gpa);
            } else if (cur == ']') {
                if (self.levels.items.len <= 1)
                    return diag.fail(.pattern, "Pattern invalid as it contains ] without previous [", .{});
                try self.optionalEnd(gpa, diag);
            } else if (cur == '{' or cur == '}' or cur == '#') {
                return diag.fail(.pattern, "Pattern includes reserved character: '{c}'", .{cur});
            } else {
                // One literal per code point, like the JVM's per-char appendLiteral.
                const n = std.unicode.utf8ByteSequenceLength(cur) catch 1;
                const end = @min(pos + n, pattern.len);
                try self.appendLiteral(gpa, pattern[pos..end]);
                pos = end - 1;
            }
        }
    }

    fn patternLetter(self: *Builder, gpa: Allocator, cur: u8, count: usize, diag: *Diag) Error!void {
        const field: ?Field = switch (cur) {
            'G' => .era,
            'y' => .year_of_era,
            'u' => .year,
            'M', 'L' => .month_of_year,
            'D' => .day_of_year,
            'd' => .day_of_month,
            'F' => .aligned_week_of_month,
            'E' => .day_of_week,
            'a' => .ampm_of_day,
            'H' => .hour_of_day,
            'k' => .clock_hour_of_day,
            'K' => .hour_of_ampm,
            'h' => .clock_hour_of_ampm,
            'm' => .minute_of_hour,
            's' => .second_of_minute,
            'S', 'n' => .nano_of_second,
            'A' => .milli_of_day,
            'N' => .nano_of_day,
            else => null,
        };
        if (field) |f| return self.patternField(gpa, cur, count, f, diag);
        switch (cur) {
            'V' => {
                if (count != 2) return diag.fail(.pattern, "Pattern letter count must be 2: {c}", .{cur});
                _ = try self.appendOwned(gpa, .zone_id);
            },
            'Z' => {
                if (count < 4) return self.appendOffset(gpa, "+HHMM", "+0000", diag);
                if (count == 4) return self.appendLocalizedOffset(gpa, .full, diag);
                if (count == 5) return self.appendOffset(gpa, "+HH:MM:ss", "Z", diag);
                return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
            },
            'O' => {
                if (count == 1) return self.appendLocalizedOffset(gpa, .short, diag);
                if (count == 4) return self.appendLocalizedOffset(gpa, .full, diag);
                return diag.fail(.pattern, "Pattern letter count must be 1 or 4: {c}", .{cur});
            },
            'X', 'x' => {
                if (count > 5) return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
                const pat = OFFSET_PATTERNS[count + @as(usize, if (count == 1) 0 else 1)];
                const zero: []const u8 = if (cur == 'X') "Z" else if (count == 1) "+00" else if (count % 2 == 0) "+0000" else "+00:00";
                return self.appendOffset(gpa, pat, zero, diag);
            },
            // Valid JVM letters cljw does not implement: quarter (IsoFields),
            // week-based fields, localized zone and day-period names, Julian
            // day, padding.
            'Q', 'q', 'c', 'e', 'Y', 'w', 'W', 'z', 'v', 'B', 'g', 'p' => return diag.fail(.pattern_letter, "{c}", .{cur}),
            else => return diag.fail(.pattern, "Unknown pattern letter: {c}", .{cur}),
        }
    }

    fn patternField(self: *Builder, gpa: Allocator, cur: u8, count: usize, f: Field, diag: *Diag) Error!void {
        const n: i64 = @intCast(count);
        switch (cur) {
            'u', 'y' => {
                if (count == 2) return self.appendValueReduced(gpa, f);
                if (count < 4) return self.appendValueRange(gpa, f, n, 19, .normal, diag);
                return self.appendValueRange(gpa, f, n, 19, .exceeds_pad, diag);
            },
            'M', 'L', 'E' => {
                const standalone = cur == 'L';
                switch (count) {
                    1, 2 => {
                        if (cur == 'E') return self.appendText(gpa, f, .short);
                        if (count == 1) return self.appendValue(gpa, f);
                        return self.appendValueWidth(gpa, f, 2, diag);
                    },
                    3 => return self.appendText(gpa, f, if (standalone) .short_standalone else .short),
                    4 => return self.appendText(gpa, f, if (standalone) .full_standalone else .full),
                    5 => return self.appendText(gpa, f, if (standalone) .narrow_standalone else .narrow),
                    else => return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur}),
                }
            },
            'a' => {
                if (count != 1) return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
                return self.appendText(gpa, f, .short);
            },
            'G' => switch (count) {
                1, 2, 3 => return self.appendText(gpa, f, .short),
                4 => return self.appendText(gpa, f, .full),
                5 => return self.appendText(gpa, f, .narrow),
                else => return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur}),
            },
            'S' => return self.appendFraction(gpa, .nano_of_second, n, n, false, diag),
            'F' => {
                if (count != 1) return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
                return self.appendValue(gpa, f);
            },
            'd', 'h', 'H', 'k', 'K', 'm', 's' => {
                if (count == 1) return self.appendValue(gpa, f);
                if (count == 2) return self.appendValueWidth(gpa, f, 2, diag);
                return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
            },
            'D' => {
                if (count == 1) return self.appendValue(gpa, f);
                if (count == 2 or count == 3) return self.appendValueRange(gpa, f, n, 3, .not_negative, diag);
                return diag.fail(.pattern, "Too many pattern letters: {c}", .{cur});
            },
            'A', 'n', 'N' => return self.appendValueRange(gpa, f, n, 19, .not_negative, diag),
            else => unreachable,
        }
    }
};

fn isPowerOfTen(v: i64) bool {
    var x = v;
    if (x < 10) return false;
    while (@rem(x, 10) == 0) x = @divExact(x, 10);
    return x == 1;
}

/// `DateTimeFormatter.ofPattern(pattern)`: SMART resolver, no zone.
pub fn compilePattern(gpa: Allocator, pattern: []const u8, diag: *Diag) Error!*Program {
    const b = try Builder.create(gpa);
    defer b.destroy(gpa);
    try b.appendPattern(gpa, pattern, diag);
    return b.toProgram(gpa, .smart);
}

// --- toString ---

/// `DateTimeFormatter.toString`: the root composite without its parentheses.
pub fn writeProgram(out: *std.ArrayList(u8), gpa: Allocator, p: *const Program) Allocator.Error!void {
    for (p.ops) |op| try writeOp(out, gpa, op);
}

fn writeOp(out: *std.ArrayList(u8), gpa: Allocator, op: Op) Allocator.Error!void {
    var b: [128]u8 = undefined;
    const s: []const u8 = switch (op) {
        .value => |v| blk: {
            if (v.reduced_base) |base| break :blk std.fmt.bufPrint(&b, "ReducedValue({s},{d},{d},{d}-01-01)", .{ v.field.display(), v.min, v.max, base }) catch unreachable;
            if (v.min == 1 and v.max == 19 and v.sign == .normal) break :blk std.fmt.bufPrint(&b, "Value({s})", .{v.field.display()}) catch unreachable;
            if (v.min == v.max and v.sign == .not_negative) break :blk std.fmt.bufPrint(&b, "Value({s},{d})", .{ v.field.display(), v.min }) catch unreachable;
            break :blk std.fmt.bufPrint(&b, "Value({s},{d},{d},{s})", .{ v.field.display(), v.min, v.max, v.sign.upper() }) catch unreachable;
        },
        .fraction => |fr| std.fmt.bufPrint(&b, "Fraction({s},{d},{d}{s})", .{ fr.field.display(), fr.min, fr.max, if (fr.decimal_point) ",DecimalPoint" else "" }) catch unreachable,
        .text => |t| if (t.style == .full)
            std.fmt.bufPrint(&b, "Text({s})", .{t.field.display()}) catch unreachable
        else
            std.fmt.bufPrint(&b, "Text({s},{s})", .{ t.field.display(), t.style.upper() }) catch unreachable,
        .literal => |lit| {
            if (std.mem.eql(u8, lit, "'")) return out.appendSlice(gpa, "''");
            try out.append(gpa, '\'');
            for (lit) |c| {
                if (c == '\'') try out.append(gpa, '\'');
                try out.append(gpa, c);
            }
            return out.append(gpa, '\'');
        },
        .offset => |o| {
            try out.appendSlice(gpa, "Offset(");
            try out.appendSlice(gpa, OFFSET_PATTERNS[o.pattern]);
            try out.appendSlice(gpa, ",'");
            for (o.no_offset_text) |c| {
                if (c == '\'') try out.append(gpa, '\'');
                try out.append(gpa, c);
            }
            return out.appendSlice(gpa, "')");
        },
        .localized_offset => |st| std.fmt.bufPrint(&b, "LocalizedOffset({s})", .{st.upper()}) catch unreachable,
        .zone_id => "ZoneId()",
        .zone_region_id => "ZoneRegionId()",
        .instant => "Instant()",
        .case_sensitive => |on| if (on) "ParseCaseSensitive(true)" else "ParseCaseSensitive(false)",
        .strict => |on| if (on) "ParseStrict(true)" else "ParseStrict(false)",
        .default_value => |d| std.fmt.bufPrint(&b, "Default({s},{d})", .{ d.field.display(), d.value }) catch unreachable,
        .composite => |c| {
            try out.append(gpa, if (c.optional) '[' else '(');
            for (c.ops) |sub| try writeOp(out, gpa, sub);
            return out.append(gpa, if (c.optional) ']' else ')');
        },
    };
    try out.appendSlice(gpa, s);
}

// --- English text ---

const MONTH_FULL = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
const MONTH_SHORT = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
const MONTH_NARROW = [_][]const u8{ "J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D" };
const DOW_FULL = [_][]const u8{ "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday" };
const DOW_SHORT = [_][]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" };
const DOW_NARROW = [_][]const u8{ "M", "T", "W", "T", "F", "S", "S" };
const AMPM = [_][]const u8{ "AM", "PM" };
const AMPM_NARROW = [_][]const u8{ "a", "p" };
const ERA_FULL = [_][]const u8{ "Before Christ", "Anno Domini" };
const ERA_SHORT = [_][]const u8{ "BC", "AD" };
const ERA_NARROW = [_][]const u8{ "B", "A" };

/// The text table for `field` in `style`, and the value of its first entry.
fn textTable(field: Field, style: TextStyle) ?struct { names: []const []const u8, first: i64 } {
    return switch (field) {
        .month_of_year => .{ .names = switch (style.base()) {
            .full => &MONTH_FULL,
            .short => &MONTH_SHORT,
            else => &MONTH_NARROW,
        }, .first = 1 },
        .day_of_week => .{ .names = switch (style.base()) {
            .full => &DOW_FULL,
            .short => &DOW_SHORT,
            else => &DOW_NARROW,
        }, .first = 1 },
        .ampm_of_day => .{ .names = if (style.base() == .narrow) &AMPM_NARROW else &AMPM, .first = 0 },
        .era => .{ .names = switch (style.base()) {
            .full => &ERA_FULL,
            .short => &ERA_SHORT,
            else => &ERA_NARROW,
        }, .first = 0 },
        else => null,
    };
}

// --- formatting ---

const PrintCtx = struct {
    t: *const Temporal,
    out: *std.ArrayList(u8),
    gpa: Allocator,
    diag: *Diag,
    optional: u32 = 0,

    /// `DateTimePrintContext.getValue`: absent inside an optional section,
    /// an UnsupportedTemporalTypeException outside one.
    fn value(self: *PrintCtx, f: Field) error{DateTime}!?i64 {
        if (self.t.getField(f)) |v| return v;
        if (self.optional > 0) return null;
        return self.diag.unsupported(f);
    }

    fn put(self: *PrintCtx, s: []const u8) Allocator.Error!void {
        try self.out.appendSlice(self.gpa, s);
    }
};

/// `DateTimeFormatter.format`: print `t` with `p` into `out`.
pub fn format(gpa: Allocator, p: *const Program, t: *const Temporal, out: *std.ArrayList(u8), diag: *Diag) Error!void {
    var ctx: PrintCtx = .{ .t = t, .out = out, .gpa = gpa, .diag = diag };
    _ = try printOps(&ctx, p.ops, false);
}

fn printOps(ctx: *PrintCtx, ops: []const Op, optional: bool) Error!bool {
    const mark = ctx.out.items.len;
    if (optional) ctx.optional += 1;
    defer {
        if (optional) ctx.optional -= 1;
    }
    for (ops) |op| {
        if (!try printOp(ctx, op)) {
            ctx.out.shrinkRetainingCapacity(mark);
            return true;
        }
    }
    return true;
}

fn printOp(ctx: *PrintCtx, op: Op) Error!bool {
    switch (op) {
        .value => |v| return printValue(ctx, v),
        .fraction => |fr| return printFraction(ctx, fr),
        .text => |t| {
            const v = try ctx.value(t.field) orelse return false;
            if (textTable(t.field, t.style)) |tbl| {
                const idx = v - tbl.first;
                if (idx >= 0 and idx < tbl.names.len) {
                    try ctx.put(tbl.names[@intCast(idx)]);
                    return true;
                }
            }
            return printValue(ctx, .{ .field = t.field, .min = 1, .max = 19, .sign = .normal });
        },
        .literal => |s| {
            try ctx.put(s);
            return true;
        },
        .offset => |o| return printOffset(ctx, o.pattern, o.no_offset_text),
        .localized_offset => |st| return printLocalizedOffset(ctx, st),
        .zone_id, .zone_region_id => {
            const zone = ctx.t.zone orelse {
                if (ctx.optional > 0) return false;
                var tb: [96]u8 = undefined;
                return ctx.diag.fail(.value, "Unable to extract ZoneId from temporal {s}", .{temporalText(&tb, ctx.t)});
            };
            if (op == .zone_region_id and !zone.isRegion()) return false;
            var zb: [24]u8 = undefined;
            try ctx.put(zone_offset.formatId(&zb, zone));
            return true;
        },
        .instant => {
            const secs = try ctx.value(.instant_seconds) orelse return false;
            const nanos = ctx.t.getField(.nano_of_second) orelse 0;
            var ib: [64]u8 = undefined;
            try ctx.put(instant.formatIsoInstant(&ib, secs * 1000, @intCast(nanos)));
            return true;
        },
        .case_sensitive, .strict, .default_value => return true,
        .composite => |c| return printOps(ctx, c.ops, c.optional),
    }
}

const EXCEED_POINTS = [_]i64{ 0, 10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000, 100_000_000, 1_000_000_000, 10_000_000_000 };

fn printValue(ctx: *PrintCtx, v: ValueOp) Error!bool {
    var val = try ctx.value(v.field) orelse return false;
    if (v.reduced_base) |base| {
        const abs: i64 = @intCast(@abs(val));
        const range = EXCEED_POINTS[v.min];
        val = if (val >= base and val < base + range) @mod(abs, range) else @mod(abs, EXCEED_POINTS[v.max]);
    }
    var db: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&db, "{d}", .{@abs(val)}) catch unreachable;
    if (digits.len > v.max)
        return ctx.diag.fail(.value, "Field {s} cannot be printed as the value {d} exceeds the maximum print width of {d}", .{ v.field.display(), val, v.max });
    if (val >= 0) {
        switch (v.sign) {
            .exceeds_pad => if (v.min < 19 and v.min < EXCEED_POINTS.len and val >= EXCEED_POINTS[v.min]) try ctx.put("+"),
            .always => try ctx.put("+"),
            else => {},
        }
    } else switch (v.sign) {
        .normal, .exceeds_pad, .always => try ctx.put("-"),
        .not_negative => return ctx.diag.fail(.value, "Field {s} cannot be printed as the value {d} cannot be negative according to the SignStyle", .{ v.field.display(), val }),
        .never => {},
    }
    var pad = @as(usize, v.min) -| digits.len;
    while (pad > 0) : (pad -= 1) try ctx.put("0");
    try ctx.put(digits);
    return true;
}

/// Digits of the field's range size (10^k): the fraction scale.
fn fractionScale(f: Field) u8 {
    var n = rangeOf(f).max + 1;
    var k: u8 = 0;
    while (n > 1) : (n = @divExact(n, 10)) k += 1;
    return k;
}

fn printFraction(ctx: *PrintCtx, fr: FractionOp) Error!bool {
    const val = try ctx.value(fr.field) orelse return false;
    if (!rangeOf(fr.field).isValid(val)) return ctx.diag.invalidValue(fr.field, val);
    const scale = fractionScale(fr.field);
    var db: [16]u8 = undefined;
    const all = std.fmt.bufPrint(&db, "{d:0>[1]}", .{ @as(u64, @intCast(val)), scale }) catch unreachable;
    var sig = all.len;
    while (sig > 0 and all[sig - 1] == '0') sig -= 1; // stripTrailingZeros
    if (sig == 0) {
        if (fr.min > 0) {
            if (fr.decimal_point) try ctx.put(".");
            var i: usize = 0;
            while (i < fr.min) : (i += 1) try ctx.put("0");
        }
        return true;
    }
    const width = @min(@max(sig, fr.min), fr.max);
    if (fr.decimal_point) try ctx.put(".");
    var i: usize = 0;
    while (i < width) : (i += 1) try ctx.put(if (i < all.len) all[i .. i + 1] else "0");
    return true;
}

fn isColonStyle(style: u8) bool {
    return style > 0 and style % 2 == 0;
}

fn printOffset(ctx: *PrintCtx, style: u8, no_offset_text: []const u8) Error!bool {
    const total = try ctx.value(.offset_seconds) orelse return false;
    if (total == 0) {
        try ctx.put(no_offset_text);
        return true;
    }
    const abs_h: u64 = @intCast(@mod(@as(i64, @intCast(@abs(@divTrunc(total, 3600)))), 100));
    const abs_m: u64 = @intCast(@abs(@rem(@divTrunc(total, 60), 60)));
    const abs_s: u64 = @intCast(@abs(@rem(total, 60)));
    const mark = ctx.out.items.len;
    var b: [16]u8 = undefined;
    try ctx.put(if (total < 0) "-" else "+");
    try ctx.put(std.fmt.bufPrint(&b, "{d:0>2}", .{abs_h}) catch unreachable);
    var output = abs_h;
    const colon = isColonStyle(style);
    if ((style >= 3 and style <= 8) or (style >= 9 and abs_s > 0) or (style >= 1 and abs_m > 0)) {
        if (colon) try ctx.put(":");
        try ctx.put(std.fmt.bufPrint(&b, "{d:0>2}", .{abs_m}) catch unreachable);
        output += abs_m;
        if (style == 7 or style == 8 or (style >= 5 and abs_s > 0)) {
            if (colon) try ctx.put(":");
            try ctx.put(std.fmt.bufPrint(&b, "{d:0>2}", .{abs_s}) catch unreachable);
            output += abs_s;
        }
    }
    if (output == 0) {
        ctx.out.shrinkRetainingCapacity(mark);
        try ctx.put(no_offset_text);
    }
    return true;
}

fn printLocalizedOffset(ctx: *PrintCtx, style: TextStyle) Error!bool {
    const total = try ctx.value(.offset_seconds) orelse return false;
    try ctx.put("GMT");
    if (total == 0) return true;
    const abs_h: u64 = @intCast(@mod(@as(i64, @intCast(@abs(@divTrunc(total, 3600)))), 100));
    const abs_m: u64 = @intCast(@abs(@rem(@divTrunc(total, 60), 60)));
    const abs_s: u64 = @intCast(@abs(@rem(total, 60)));
    var b: [16]u8 = undefined;
    try ctx.put(if (total < 0) "-" else "+");
    if (style == .full) {
        try ctx.put(std.fmt.bufPrint(&b, "{d:0>2}:{d:0>2}", .{ abs_h, abs_m }) catch unreachable);
        if (abs_s != 0) try ctx.put(std.fmt.bufPrint(&b, ":{d:0>2}", .{abs_s}) catch unreachable);
    } else {
        try ctx.put(std.fmt.bufPrint(&b, "{d}", .{abs_h}) catch unreachable);
        if (abs_m != 0 or abs_s != 0) {
            try ctx.put(std.fmt.bufPrint(&b, ":{d:0>2}", .{abs_m}) catch unreachable);
            if (abs_s != 0) try ctx.put(std.fmt.bufPrint(&b, ":{d:0>2}", .{abs_s}) catch unreachable);
        }
    }
    return true;
}

/// A short rendering of a temporal for an error message (the JVM prints the
/// value's toString).
pub fn temporalText(buf: []u8, t: *const Temporal) []const u8 {
    if (t.date) |ed| {
        var db: [24]u8 = undefined;
        const ds = instant.formatLocalDate(&db, ed);
        if (t.time) |nod| {
            var tb: [24]u8 = undefined;
            return std.fmt.bufPrint(buf, "{s}T{s}", .{ ds, instant.formatLocalTime(&tb, nod) }) catch buf[0..0];
        }
        return std.fmt.bufPrint(buf, "{s}", .{ds}) catch buf[0..0]; // ds lives in db, not buf
    }
    if (t.time) |nod| return instant.formatLocalTime(buf, nod);
    if (t.instant_secs) |s| return instant.formatIsoInstant(buf, s * 1000, t.instant_nanos);
    return buf[0..0];
}

// --- parsing ---

const ParseState = struct {
    fields: FieldSet = .{},
    zone: ?Zone = null,
};

const ParseCtx = struct {
    text: []const u8,
    case_sensitive: bool = true,
    strict: bool = true,
    state: ParseState = .{},
    diag: *Diag,

    /// `setParsedField`: a second, different value for one field fails.
    fn setField(self: *ParseCtx, f: Field, v: i64, err_pos: usize, ok_pos: usize) i64 {
        const old = self.state.fields.put(f, v);
        if (old != null and old.? != v) return fail(err_pos);
        return @intCast(ok_pos);
    }

    fn regionMatches(self: *const ParseCtx, pos: usize, s: []const u8) bool {
        if (pos + s.len > self.text.len) return false;
        const t = self.text[pos .. pos + s.len];
        return if (self.case_sensitive) std.mem.eql(u8, t, s) else std.ascii.eqlIgnoreCase(t, s);
    }
};

/// The JVM's `~position` error encoding.
fn fail(pos: usize) i64 {
    return ~@as(i64, @intCast(pos));
}

/// How a parse failed, before resolution: `index` is where the text stopped
/// matching; `unparsed` means the whole program matched but text was left.
pub const ParseFailure = union(enum) { index: usize, unparsed: usize };

/// `DateTimeFormatter.parse(text)` to the resolved field set. On a parse
/// failure returns `error.Parse` with `failure` set; on a resolve failure
/// returns `error.DateTime` with `diag` set (the caller words it as
/// "could not be parsed: <msg>").
pub fn parse(p: *const Program, text: []const u8, diag: *Diag, failure: *ParseFailure) (Error || error{Parse})!Parsed {
    var ctx: ParseCtx = .{ .text = text, .diag = diag };
    const r = try parseOps(&ctx, p.ops, 0, false);
    if (r < 0) {
        failure.* = .{ .index = @intCast(~r) };
        return error.Parse;
    }
    if (r != text.len) {
        failure.* = .{ .unparsed = @intCast(r) };
        return error.Parse;
    }
    var parsed: Parsed = .{ .fields = ctx.state.fields, .zone = ctx.state.zone orelse p.zone };
    try parsed.resolve(p.resolver, diag);
    return parsed;
}

fn parseOps(ctx: *ParseCtx, ops: []const Op, position: usize, optional: bool) error{DateTime}!i64 {
    if (optional) {
        const saved = ctx.state;
        var pos: i64 = @intCast(position);
        for (ops, 0..) |op, i| {
            pos = try parseOp(ctx, ops, i, op, @intCast(pos));
            if (pos < 0) {
                ctx.state = saved;
                return @intCast(position);
            }
        }
        return pos;
    }
    var pos: i64 = @intCast(position);
    for (ops, 0..) |op, i| {
        pos = try parseOp(ctx, ops, i, op, @intCast(pos));
        if (pos < 0) break;
    }
    return pos;
}

fn parseOp(ctx: *ParseCtx, ops: []const Op, idx: usize, op: Op, pos: usize) error{DateTime}!i64 {
    _ = ops;
    _ = idx;
    switch (op) {
        .value => |v| return parseValue(ctx, v, pos),
        .fraction => |fr| return parseFraction(ctx, fr, pos),
        .text => |t| return parseText(ctx, t.field, t.style, pos),
        .literal => |s| {
            if (pos > ctx.text.len) return fail(pos);
            if (!ctx.regionMatches(pos, s)) return fail(pos);
            return @intCast(pos + s.len);
        },
        .offset => |o| return parseOffset(ctx, o.pattern, o.no_offset_text, pos),
        .localized_offset => |st| return parseLocalizedOffset(ctx, st, pos),
        .zone_id, .zone_region_id => return parseZone(ctx, pos),
        .instant => return parseInstant(ctx, pos),
        .case_sensitive => |on| {
            ctx.case_sensitive = on;
            return @intCast(pos);
        },
        .strict => |on| {
            ctx.strict = on;
            return @intCast(pos);
        },
        .default_value => |d| {
            if (!ctx.state.fields.has(d.field)) _ = ctx.state.fields.put(d.field, d.value);
            return @intCast(pos);
        },
        .composite => |c| return parseOps(ctx, c.ops, pos, c.optional),
    }
}

fn digitAt(text: []const u8, pos: usize) ?u8 {
    if (pos >= text.len) return null;
    const c = text[pos];
    return if (c >= '0' and c <= '9') c - '0' else null;
}

fn isFixedWidth(v: ValueOp, strict: bool) bool {
    if (v.reduced_base != null and !strict) return false;
    return v.subsequent == -1 or (v.subsequent > 0 and v.min == v.max and v.sign == .not_negative);
}

/// `NumberPrinterParser.parse` (and the ReducedPrinterParser window).
fn parseValue(ctx: *ParseCtx, v: ValueOp, position_in: usize) error{DateTime}!i64 {
    var position = position_in;
    const text = ctx.text;
    if (position >= text.len) return fail(position);
    const fixed = isFixedWidth(v, ctx.strict);
    const eff_min: usize = if (ctx.strict or fixed) v.min else 1;
    var negative = false;
    var positive = false;
    const sign = text[position];
    if (sign == '+') {
        if (!v.sign.allows(true, ctx.strict, v.min == v.max)) return fail(position);
        positive = true;
        position += 1;
    } else if (sign == '-') {
        if (!v.sign.allows(false, ctx.strict, v.min == v.max)) return fail(position);
        negative = true;
        position += 1;
    } else if (v.sign == .always and ctx.strict) {
        return fail(position);
    }
    var eff_max: usize = (if (ctx.strict or fixed) @as(usize, v.max) else 9) + @as(usize, @intCast(@max(v.subsequent, 0)));
    const min_end = position + eff_min;
    if (min_end > text.len) return fail(position);
    var total: i128 = 0;
    var pos = position;
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        const max_end = @min(pos + eff_max, text.len);
        while (pos < max_end) {
            const d = digitAt(text, pos) orelse {
                if (pos < min_end) return fail(position);
                break;
            };
            total = total * 10 + d;
            pos += 1;
        }
        if (v.subsequent > 0 and pass == 0) {
            const parse_len = pos - position;
            eff_max = @max(eff_min, parse_len -| @as(usize, @intCast(v.subsequent)));
            pos = position;
            total = 0;
        } else break;
    }
    if (total > std.math.maxInt(i64)) return fail(position);
    if (negative) {
        if (total == 0 and ctx.strict) return fail(position - 1);
        total = -total;
    } else if (v.sign == .exceeds_pad and ctx.strict) {
        const parse_len = pos - position;
        if (positive) {
            if (parse_len <= v.min) return fail(position - 1);
        } else if (parse_len > v.min) {
            return fail(position);
        }
    }
    var value: i64 = @intCast(total);
    if (v.reduced_base) |base| {
        const parse_len = pos - position;
        if (parse_len == v.min and value >= 0) {
            const range = EXCEED_POINTS[parse_len];
            const last = @mod(base, range);
            const base_part = base - last;
            value = if (base > 0) base_part + value else base_part - value;
            if (value < base) value += range;
        }
    }
    return ctx.setField(v.field, value, position, pos);
}

/// `FractionPrinterParser.parse`.
fn parseFraction(ctx: *ParseCtx, fr: FractionOp, position_in: usize) error{DateTime}!i64 {
    var position = position_in;
    const text = ctx.text;
    const eff_min: usize = if (ctx.strict) fr.min else 0;
    const eff_max: usize = if (ctx.strict) fr.max else 9;
    if (position == text.len) return if (eff_min > 0) fail(position) else @intCast(position);
    if (fr.decimal_point) {
        if (text[position] != '.') return if (eff_min > 0) fail(position) else @intCast(position);
        position += 1;
    }
    const min_end = position + eff_min;
    if (min_end > text.len) return fail(position);
    const max_end = @min(position + eff_max, text.len);
    var total: i64 = 0;
    var pos = position;
    while (pos < max_end) {
        const d = digitAt(text, pos) orelse {
            if (pos < min_end) return fail(position);
            break;
        };
        total = total * 10 + d;
        pos += 1;
    }
    // value = floor(total / 10^digits × 10^scale)
    const digits = pos - position;
    const scale = fractionScale(fr.field);
    var value: i64 = total;
    if (digits > scale) {
        var k = digits - scale;
        while (k > 0) : (k -= 1) value = @divFloor(value, 10);
    } else {
        var k = scale - digits;
        while (k > 0) : (k -= 1) value *= 10;
    }
    return ctx.setField(fr.field, value, position, pos);
}

fn parseText(ctx: *ParseCtx, field: Field, style: TextStyle, position: usize) error{DateTime}!i64 {
    if (textTable(field, style)) |_| {
        // Strict: the one style; lenient: every style. Longest match wins.
        const styles: []const TextStyle = if (ctx.strict) &.{style} else &.{ .full, .short, .narrow };
        var best_len: usize = 0;
        var best_val: i64 = 0;
        for (styles) |st| {
            const tbl = textTable(field, st).?;
            for (tbl.names, 0..) |nm, i| {
                if (nm.len > best_len and ctx.regionMatches(position, nm)) {
                    best_len = nm.len;
                    best_val = tbl.first + @as(i64, @intCast(i));
                }
            }
        }
        if (best_len > 0) return ctx.setField(field, best_val, position, position + best_len);
        if (ctx.strict) return fail(position);
    }
    return parseValue(ctx, .{ .field = field, .min = 1, .max = 19, .sign = .normal }, position);
}

/// Two digits at `array[0]`, after a colon when `colon` and not the hour.
fn offsetDigits(text: []const u8, colon: bool, index: usize, array: *[4]i64) bool {
    var pos = array[0];
    if (pos < 0) return true;
    if (colon and index != 1) {
        if (pos + 1 > text.len or text[@intCast(pos)] != ':') return false;
        pos += 1;
    }
    if (pos + 2 > text.len) return false;
    const a = digitAt(text, @intCast(pos)) orelse return false;
    const b = digitAt(text, @intCast(pos + 1)) orelse return false;
    const v: i64 = @as(i64, a) * 10 + b;
    if (v > 59) return false;
    array[index] = v;
    array[0] = pos + 2;
    return true;
}

/// `OffsetIdPrinterParser.parse` (padded-hour patterns).
fn parseOffset(ctx: *ParseCtx, style: u8, no_offset_text: []const u8, position: usize) error{DateTime}!i64 {
    const text = ctx.text;
    if (no_offset_text.len == 0) {
        if (position == text.len) return ctx.setField(.offset_seconds, 0, position, position);
    } else {
        if (position == text.len) return fail(position);
        if (ctx.regionMatches(position, no_offset_text))
            return ctx.setField(.offset_seconds, 0, position, position + no_offset_text.len);
    }
    const sign = text[position];
    if (sign == '+' or sign == '-') {
        const negative: i64 = if (sign == '-') -1 else 1;
        var colon = isColonStyle(style);
        var array = [4]i64{ @intCast(position + 1), 0, 0, 0 };
        var parse_type = style;
        if (!ctx.strict) {
            if (colon or (parse_type == 0 and text.len > position + 3 and text[position + 3] == ':')) {
                colon = true;
                parse_type = 10;
            } else parse_type = 9;
        }
        if (!offsetDigits(text, false, 1, &array)) array[0] = ~array[0];
        switch (parse_type) {
            0 => {},
            1, 2 => _ = offsetDigits(text, colon, 2, &array),
            3, 4 => if (!offsetDigits(text, colon, 2, &array)) {
                array[0] = ~array[0];
            },
            5, 6 => {
                if (!offsetDigits(text, colon, 2, &array)) array[0] = ~array[0];
                _ = offsetDigits(text, colon, 3, &array);
            },
            7, 8 => {
                if (!offsetDigits(text, colon, 2, &array)) array[0] = ~array[0];
                if (!offsetDigits(text, colon, 3, &array)) array[0] = ~array[0];
            },
            9, 10 => if (offsetDigits(text, colon, 2, &array)) {
                _ = offsetDigits(text, colon, 3, &array);
            },
            else => unreachable,
        }
        if (array[0] > 0) {
            if (array[1] > 23 or array[2] > 59 or array[3] > 59)
                return ctx.diag.fail(.value, "Value out of range: Hour[0-23], Minute[0-59], Second[0-59]", .{});
            const secs = negative * (array[1] * 3600 + array[2] * 60 + array[3]);
            return ctx.setField(.offset_seconds, secs, position, @intCast(array[0]));
        }
    }
    if (no_offset_text.len == 0) return ctx.setField(.offset_seconds, 0, position, position);
    return fail(position);
}

/// `LocalizedOffsetIdPrinterParser.parse`: `GMT`, then an optional signed
/// `h[h][:mm[:ss]]` (SHORT) or `hh:mm[:ss]` (FULL).
fn parseLocalizedOffset(ctx: *ParseCtx, style: TextStyle, position: usize) error{DateTime}!i64 {
    const text = ctx.text;
    if (!ctx.regionMatches(position, "GMT")) return fail(position);
    var pos = position + 3;
    if (pos == text.len) return ctx.setField(.offset_seconds, 0, position, pos);
    const negative: i64 = switch (text[pos]) {
        '+' => 1,
        '-' => -1,
        else => return ctx.setField(.offset_seconds, 0, position, pos),
    };
    pos += 1;
    var h: i64 = 0;
    var m: i64 = 0;
    var s: i64 = 0;
    if (style == .full) {
        const h1 = digitAt(text, pos) orelse return fail(position);
        const h2 = digitAt(text, pos + 1) orelse return fail(position);
        if (pos + 2 >= text.len or text[pos + 2] != ':') return fail(position);
        h = @as(i64, h1) * 10 + h2;
        const m1 = digitAt(text, pos + 3) orelse return fail(position);
        const m2 = digitAt(text, pos + 4) orelse return fail(position);
        m = @as(i64, m1) * 10 + m2;
        pos += 5;
        if (pos + 2 < text.len and text[pos] == ':') {
            if (digitAt(text, pos + 1)) |s1| if (digitAt(text, pos + 2)) |s2| {
                s = @as(i64, s1) * 10 + s2;
                pos += 3;
            };
        }
    } else {
        h = digitAt(text, pos) orelse return fail(position);
        pos += 1;
        if (pos < text.len) {
            if (digitAt(text, pos)) |h2| {
                h = h * 10 + h2;
                pos += 1;
            }
            if (pos + 2 < text.len and text[pos] == ':') {
                if (digitAt(text, pos + 1)) |m1| if (digitAt(text, pos + 2)) |m2| {
                    m = @as(i64, m1) * 10 + m2;
                    pos += 3;
                    if (pos + 2 < text.len and text[pos] == ':') {
                        if (digitAt(text, pos + 1)) |s1| if (digitAt(text, pos + 2)) |s2| {
                            s = @as(i64, s1) * 10 + s2;
                            pos += 3;
                        };
                    }
                };
            }
        }
    }
    return ctx.setField(.offset_seconds, negative * (h * 3600 + m * 60 + s), position, pos);
}

/// A zone id: the longest prefix that `ZoneId.of` accepts. Region ids beyond
/// UTC / GMT / UT need the tz database cljw does not ship, so they fail to
/// parse (which an optional section absorbs).
fn parseZone(ctx: *ParseCtx, position: usize) error{DateTime}!i64 {
    const text = ctx.text;
    var end = position;
    while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or std.mem.indexOfScalar(u8, "~/._+-:", text[end]) != null)) end += 1;
    var len = end - position;
    while (len > 0) : (len -= 1) {
        var d: zone_offset.Diag = .{};
        const zone = zone_offset.parseZoneId(text[position .. position + len], &d) catch continue;
        ctx.state.zone = zone;
        return @intCast(position + len);
    }
    return fail(position);
}

/// The ISO_INSTANT parse: ISO local date 'T' HH:mm:ss[.fraction] offset.
const INSTANT_OPS = [_]Op{
    .{ .composite = .{ .ops = &ISO_LOCAL_DATE_OPS, .optional = false } },
    .{ .literal = "T" },
    .{ .value = .{ .field = .hour_of_day, .min = 2, .max = 2, .sign = .not_negative } },
    .{ .literal = ":" },
    .{ .value = .{ .field = .minute_of_hour, .min = 2, .max = 2, .sign = .not_negative } },
    .{ .literal = ":" },
    .{ .value = .{ .field = .second_of_minute, .min = 2, .max = 2, .sign = .not_negative } },
    .{ .fraction = .{ .field = .nano_of_second, .min = 0, .max = 9, .decimal_point = true } },
    .{ .offset = .{ .pattern = 6, .no_offset_text = "Z" } },
};

fn parseInstant(ctx: *ParseCtx, position: usize) error{DateTime}!i64 {
    var sub: ParseCtx = .{ .text = ctx.text, .case_sensitive = ctx.case_sensitive, .strict = ctx.strict, .diag = ctx.diag };
    const pos = try parseOps(&sub, &INSTANT_OPS, position, false);
    if (pos < 0) return pos;
    const f = &sub.state.fields;
    const year = f.get(.year).?;
    const month = f.get(.month_of_year).?;
    const day = f.get(.day_of_month).?;
    var hour = f.get(.hour_of_day).?;
    const min = f.get(.minute_of_hour).?;
    var sec = f.get(.second_of_minute) orelse 0;
    const nano = f.get(.nano_of_second) orelse 0;
    const offset = f.get(.offset_seconds).?;
    var days: i64 = 0;
    if (hour == 24 and min == 0 and sec == 0 and nano == 0) {
        hour = 0;
        days = 1;
    } else if (hour == 23 and min == 59 and sec == 60) {
        sec = 59;
    }
    _ = try checkValid(.year, year, ctx.diag);
    _ = try checkValid(.month_of_year, month, ctx.diag);
    _ = try checkValid(.day_of_month, day, ctx.diag);
    _ = try checkValid(.hour_of_day, hour, ctx.diag);
    _ = try checkValid(.minute_of_hour, min, ctx.diag);
    _ = try checkValid(.second_of_minute, sec, ctx.diag);
    const ed = (try dateOf(year, month, day, ctx.diag)) + days;
    const secs = ed * 86_400 + hour * 3600 + min * 60 + sec - offset;
    const r = ctx.setField(.instant_seconds, secs, position, @intCast(pos));
    if (r < 0) return r;
    return ctx.setField(.nano_of_second, nano, position, @intCast(r));
}

/// `LocalDate.of` validation: the epoch day, or "Invalid date …".
fn dateOf(y: i64, m: i64, d: i64, diag: *Diag) error{DateTime}!i64 {
    if (d > 28 and d > instant.lengthOfMonth(y, m)) {
        if (d == 29) return diag.fail(.value, "Invalid date 'February 29' as '{d}' is not a leap year", .{y});
        return diag.fail(.value, "Invalid date '{s} {d}'", .{ host_enum.name(.month, @intCast(m - 1)), d });
    }
    return instant.daysFromCivil(y, m, d);
}

// --- resolution ---

/// `java.time.format.Parsed` after `resolve`: the leftover fields plus the
/// resolved date / time and the zone.
pub const Parsed = struct {
    fields: FieldSet,
    zone: ?Zone = null,
    date: ?i64 = null,
    time: ?i64 = null,
    excess_days: i64 = 0,
    resolver: ResolverStyle = .smart,

    pub fn temporal(self: *const Parsed) Temporal {
        return .{ .date = self.date, .time = self.time, .zone = self.zone, .fields = &self.fields };
    }

    fn addFieldValue(self: *Parsed, f: Field, v: i64, diag: *Diag) error{DateTime}!void {
        if (self.fields.get(f)) |old| {
            if (old != v) return diag.fail(.value, "Conflict found: {s} {d} differs from {s} {d}", .{ f.display(), old, f.display(), v });
        }
        _ = self.fields.put(f, v);
    }

    fn updateCheckConflict(self: *Parsed, target: Field, change: Field, v: i64, diag: *Diag) error{DateTime}!void {
        const old = self.fields.put(change, v);
        if (old != null and old.? != v)
            return diag.fail(.value, "Conflict found: {s} {d} differs from {s} {d} while resolving  {s}", .{ change.display(), old.?, change.display(), v, target.display() });
    }

    fn setDate(self: *Parsed, ed: i64, diag: *Diag) error{DateTime}!void {
        if (self.date) |cur| {
            if (cur != ed) {
                var a: [24]u8 = undefined;
                var b: [24]u8 = undefined;
                return diag.fail(.value, "Conflict found: Fields resolved to two different dates: {s} {s}", .{ instant.formatLocalDate(&a, cur), instant.formatLocalDate(&b, ed) });
            }
        } else self.date = ed;
    }

    fn setTime(self: *Parsed, nod: i64, excess: i64, diag: *Diag) error{DateTime}!void {
        if (self.time) |cur| {
            if (cur != nod) {
                var a: [24]u8 = undefined;
                var b: [24]u8 = undefined;
                return diag.fail(.value, "Conflict found: Fields resolved to different times: {s} {s}", .{ instant.formatLocalTime(&a, cur), instant.formatLocalTime(&b, nod) });
            }
            if (self.excess_days != 0 and excess != 0 and self.excess_days != excess)
                return diag.fail(.value, "Conflict found: Fields resolved to different excess periods: P{d}D P{d}D", .{ self.excess_days, excess });
            self.excess_days = excess;
        } else {
            self.time = nod;
            self.excess_days = excess;
        }
    }

    /// `Parsed.resolve` for the ISO chronology, SMART or STRICT.
    pub fn resolve(self: *Parsed, style: ResolverStyle, diag: *Diag) error{DateTime}!void {
        self.resolver = style;
        try self.resolveDate(diag);
        try self.resolveTimeFields(diag);
        try self.resolveTimeLenient(diag);
        try self.crossCheck(diag);
        if (self.date != null and self.time != null and self.excess_days != 0) {
            self.date = self.date.? + self.excess_days;
            self.excess_days = 0;
        }
        self.resolveFractional();
        self.resolveInstant();
    }

    fn resolveDate(self: *Parsed, diag: *Diag) error{DateTime}!void {
        const f = &self.fields;
        if (f.remove(.epoch_day)) |ed| return self.setDate(try checkValid(.epoch_day, ed, diag), diag);
        if (f.remove(.proleptic_month)) |pm| {
            _ = try checkValid(.proleptic_month, pm, diag);
            try self.addFieldValue(.month_of_year, @mod(pm, 12) + 1, diag);
            try self.addFieldValue(.year, @divFloor(pm, 12), diag);
        }
        if (f.remove(.year_of_era)) |yoe| {
            _ = try checkValid(.year_of_era, yoe, diag);
            if (f.remove(.era)) |era| {
                if (era == 1) {
                    try self.addFieldValue(.year, yoe, diag);
                } else if (era == 0) {
                    try self.addFieldValue(.year, 1 - yoe, diag);
                } else return diag.fail(.value, "Invalid value for era: {d}", .{era});
            } else if (self.resolver == .strict) {
                if (f.get(.year)) |y| {
                    try self.addFieldValue(.year, if (y > 0) yoe else 1 - yoe, diag);
                } else _ = f.put(.year_of_era, yoe);
            } else {
                const y = f.get(.year);
                try self.addFieldValue(.year, if (y == null or y.? > 0) yoe else 1 - yoe, diag);
            }
        } else if (f.get(.era)) |era| {
            _ = try checkValid(.era, era, diag);
        }
        if (!f.has(.year)) return;
        if (f.has(.month_of_year) and f.has(.day_of_month)) {
            const y = try checkValid(.year, f.remove(.year).?, diag);
            const m = try checkValid(.month_of_year, f.remove(.month_of_year).?, diag);
            var d = try checkValid(.day_of_month, f.remove(.day_of_month).?, diag);
            if (self.resolver == .smart) {
                if (m == 4 or m == 6 or m == 9 or m == 11) {
                    d = @min(d, 30);
                } else if (m == 2) d = @min(d, instant.lengthOfMonth(y, 2));
            }
            return self.setDate(try dateOf(y, m, d, diag), diag);
        }
        if (f.has(.day_of_year)) {
            const y = try checkValid(.year, f.remove(.year).?, diag);
            const doy = try checkValid(.day_of_year, f.remove(.day_of_year).?, diag);
            if (doy == 366 and !instant.isLeap(y))
                return diag.fail(.value, "Invalid date 'DayOfYear 366' as '{d}' is not a leap year", .{y});
            return self.setDate(instant.daysFromCivil(y, 1, 1) + doy - 1, diag);
        }
    }

    fn checkUnlessZero(self: *Parsed, f: Field, v: i64, diag: *Diag) error{DateTime}!void {
        if (self.resolver == .strict or v != 0) _ = try checkValid(f, v, diag);
    }

    fn resolveTimeFields(self: *Parsed, diag: *Diag) error{DateTime}!void {
        const f = &self.fields;
        if (f.remove(.clock_hour_of_day)) |ch| {
            try self.checkUnlessZero(.clock_hour_of_day, ch, diag);
            try self.updateCheckConflict(.clock_hour_of_day, .hour_of_day, if (ch == 24) 0 else ch, diag);
        }
        if (f.remove(.clock_hour_of_ampm)) |ch| {
            try self.checkUnlessZero(.clock_hour_of_ampm, ch, diag);
            try self.updateCheckConflict(.clock_hour_of_ampm, .hour_of_ampm, if (ch == 12) 0 else ch, diag);
        }
        if (f.has(.ampm_of_day) and f.has(.hour_of_ampm)) {
            const ap = try checkValid(.ampm_of_day, f.remove(.ampm_of_day).?, diag);
            const hap = try checkValid(.hour_of_ampm, f.remove(.hour_of_ampm).?, diag);
            try self.updateCheckConflict(.ampm_of_day, .hour_of_day, ap * 12 + hap, diag);
        }
        if (f.remove(.nano_of_day)) |nod| {
            _ = try checkValid(.nano_of_day, nod, diag);
            try self.updateCheckConflict(.nano_of_day, .hour_of_day, @divFloor(nod, 3_600_000_000_000), diag);
            try self.updateCheckConflict(.nano_of_day, .minute_of_hour, @mod(@divFloor(nod, 60_000_000_000), 60), diag);
            try self.updateCheckConflict(.nano_of_day, .second_of_minute, @mod(@divFloor(nod, 1_000_000_000), 60), diag);
            try self.updateCheckConflict(.nano_of_day, .nano_of_second, @mod(nod, 1_000_000_000), diag);
        }
        if (f.remove(.micro_of_day)) |cod| {
            _ = try checkValid(.micro_of_day, cod, diag);
            try self.updateCheckConflict(.micro_of_day, .second_of_day, @divFloor(cod, 1_000_000), diag);
            try self.updateCheckConflict(.micro_of_day, .micro_of_second, @mod(cod, 1_000_000), diag);
        }
        if (f.remove(.milli_of_day)) |lod| {
            _ = try checkValid(.milli_of_day, lod, diag);
            try self.updateCheckConflict(.milli_of_day, .second_of_day, @divFloor(lod, 1000), diag);
            try self.updateCheckConflict(.milli_of_day, .milli_of_second, @mod(lod, 1000), diag);
        }
        if (f.remove(.second_of_day)) |sod| {
            _ = try checkValid(.second_of_day, sod, diag);
            try self.updateCheckConflict(.second_of_day, .hour_of_day, @divFloor(sod, 3600), diag);
            try self.updateCheckConflict(.second_of_day, .minute_of_hour, @mod(@divFloor(sod, 60), 60), diag);
            try self.updateCheckConflict(.second_of_day, .second_of_minute, @mod(sod, 60), diag);
        }
        if (f.remove(.minute_of_day)) |mod| {
            _ = try checkValid(.minute_of_day, mod, diag);
            try self.updateCheckConflict(.minute_of_day, .hour_of_day, @divFloor(mod, 60), diag);
            try self.updateCheckConflict(.minute_of_day, .minute_of_hour, @mod(mod, 60), diag);
        }
        if (f.get(.nano_of_second)) |nos_in| {
            var nos = try checkValid(.nano_of_second, nos_in, diag);
            if (f.remove(.micro_of_second)) |cos| {
                _ = try checkValid(.micro_of_second, cos, diag);
                nos = cos * 1000 + @mod(nos, 1000);
                try self.updateCheckConflict(.micro_of_second, .nano_of_second, nos, diag);
            }
            if (f.remove(.milli_of_second)) |los| {
                _ = try checkValid(.milli_of_second, los, diag);
                try self.updateCheckConflict(.milli_of_second, .nano_of_second, los * 1_000_000 + @mod(nos, 1_000_000), diag);
            }
        }
        if (f.has(.hour_of_day) and f.has(.minute_of_hour) and f.has(.second_of_minute) and f.has(.nano_of_second)) {
            const hod = f.remove(.hour_of_day).?;
            const moh = f.remove(.minute_of_hour).?;
            const som = f.remove(.second_of_minute).?;
            const nos = f.remove(.nano_of_second).?;
            try self.resolveTime(hod, moh, som, nos, diag);
        }
    }

    fn resolveTimeLenient(self: *Parsed, diag: *Diag) error{DateTime}!void {
        const f = &self.fields;
        if (self.time == null) {
            if (f.remove(.milli_of_second)) |los| {
                if (f.get(.micro_of_second)) |cos_in| {
                    const cos = los * 1000 + @mod(cos_in, 1000);
                    try self.updateCheckConflict(.milli_of_second, .micro_of_second, cos, diag);
                    _ = f.remove(.micro_of_second);
                    _ = f.put(.nano_of_second, cos * 1000);
                } else _ = f.put(.nano_of_second, los * 1_000_000);
            } else if (f.remove(.micro_of_second)) |cos| {
                _ = f.put(.nano_of_second, cos * 1000);
            }
            if (f.get(.hour_of_day)) |hod| {
                const moh = f.get(.minute_of_hour);
                const som = f.get(.second_of_minute);
                const nos = f.get(.nano_of_second);
                const undefaultable = (moh == null and (som != null or nos != null)) or (moh != null and som == null and nos != null);
                if (!undefaultable) {
                    try self.resolveTime(hod, moh orelse 0, som orelse 0, nos orelse 0, diag);
                    _ = f.remove(.hour_of_day);
                    _ = f.remove(.minute_of_hour);
                    _ = f.remove(.second_of_minute);
                    _ = f.remove(.nano_of_second);
                }
            }
        }
        // Validate the time-based fields left over.
        for (0..FIELD_COUNT) |i| {
            const fld: Field = @enumFromInt(i);
            if (!fld.isTimeBased()) continue;
            if (f.get(fld)) |v| _ = try checkValid(fld, v, diag);
        }
    }

    fn resolveTime(self: *Parsed, hod: i64, moh: i64, som: i64, nos: i64, diag: *Diag) error{DateTime}!void {
        const m = try checkValid(.minute_of_hour, moh, diag);
        const n = try checkValid(.nano_of_second, nos, diag);
        if (self.resolver == .smart and hod == 24 and m == 0 and som == 0 and n == 0)
            return self.setTime(0, 1, diag);
        const h = try checkValid(.hour_of_day, hod, diag);
        const s = try checkValid(.second_of_minute, som, diag);
        try self.setTime(((h * 60 + m) * 60 + s) * 1_000_000_000 + n, 0, diag);
    }

    /// Every leftover field the resolved date / time also carries must agree
    /// with it, and is then dropped.
    fn crossCheck(self: *Parsed, diag: *Diag) error{DateTime}!void {
        if (self.date == null and self.time == null) return;
        const view: Temporal = .{ .date = self.date, .time = self.time };
        for (0..FIELD_COUNT) |i| {
            const fld: Field = @enumFromInt(i);
            const v2 = self.fields.get(fld) orelse continue;
            const v1 = view.getField(fld) orelse continue;
            if (v1 != v2) {
                var tb: [64]u8 = undefined;
                return diag.fail(.value, "Conflict found: Field {s} {d} differs from {s} {d} derived from {s}", .{ fld.display(), v1, fld.display(), v2, temporalText(&tb, &view) });
            }
            _ = self.fields.remove(fld);
        }
    }

    fn resolveFractional(self: *Parsed) void {
        const f = &self.fields;
        if (self.time == null and (f.has(.instant_seconds) or f.has(.second_of_day) or f.has(.second_of_minute))) {
            if (f.get(.nano_of_second)) |nos| {
                _ = f.put(.micro_of_second, @divFloor(nos, 1000));
                _ = f.put(.milli_of_second, @divFloor(nos, 1_000_000));
            } else {
                _ = f.put(.nano_of_second, 0);
                _ = f.put(.micro_of_second, 0);
                _ = f.put(.milli_of_second, 0);
            }
        }
    }

    fn resolveInstant(self: *Parsed) void {
        const ed = self.date orelse return;
        const nod = self.time orelse return;
        const offset: i64 = self.fields.get(.offset_seconds) orelse if (self.zone) |z| z.seconds else return;
        _ = self.fields.put(.instant_seconds, ed * 86_400 + @divFloor(nod, 1_000_000_000) - offset);
    }

    /// `Parsed.toString`: `{F=v, …},ISO[,zone][ resolved to date[Ttime]]`.
    pub fn write(self: *const Parsed, out: *std.ArrayList(u8), gpa: Allocator) Allocator.Error!void {
        var b: [64]u8 = undefined;
        try out.append(gpa, '{');
        var first = true;
        for (0..FIELD_COUNT) |i| {
            const fld: Field = @enumFromInt(i);
            const v = self.fields.get(fld) orelse continue;
            if (!first) try out.appendSlice(gpa, ", ");
            first = false;
            try out.appendSlice(gpa, std.fmt.bufPrint(&b, "{s}={d}", .{ fld.display(), v }) catch unreachable);
        }
        try out.appendSlice(gpa, "},ISO");
        if (self.zone) |z| {
            try out.append(gpa, ',');
            try out.appendSlice(gpa, zone_offset.formatId(&b, z));
        }
        if (self.date != null or self.time != null) {
            try out.appendSlice(gpa, " resolved to ");
            const view: Temporal = .{ .date = self.date, .time = self.time };
            try out.appendSlice(gpa, temporalText(&b, &view));
        }
    }
};

// --- the ISO constants ---

fn isoValue(f: Field, min: u8, max: u8, sign: SignStyle) Op {
    return .{ .value = .{ .field = f, .min = min, .max = max, .sign = sign } };
}

fn isoFixed(f: Field, w: u8) Op {
    return isoValue(f, w, w, .not_negative);
}

fn comp(ops: []const Op, optional: bool) Op {
    return .{ .composite = .{ .ops = ops, .optional = optional } };
}

const OFFSET_ID: Op = .{ .offset = .{ .pattern = 6, .no_offset_text = "Z" } };

const ISO_LOCAL_DATE_OPS = [_]Op{ isoValue(.year, 4, 10, .exceeds_pad), .{ .literal = "-" }, isoFixed(.month_of_year, 2), .{ .literal = "-" }, isoFixed(.day_of_month, 2) };
const FRACTION_TAIL = [_]Op{.{ .fraction = .{ .field = .nano_of_second, .min = 0, .max = 9, .decimal_point = true } }};
const SECONDS_TAIL = [_]Op{ .{ .literal = ":" }, isoFixed(.second_of_minute, 2), comp(&FRACTION_TAIL, true) };
const ISO_LOCAL_TIME_OPS = [_]Op{ isoFixed(.hour_of_day, 2), .{ .literal = ":" }, isoFixed(.minute_of_hour, 2), comp(&SECONDS_TAIL, true) };
const ISO_LOCAL_DATE_TIME_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_DATE_OPS, false), .{ .literal = "T" }, comp(&ISO_LOCAL_TIME_OPS, false) };
const ISO_OFFSET_DATE_TIME_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_DATE_TIME_OPS, false), .{ .strict = false }, OFFSET_ID, .{ .strict = true } };
const ISO_OFFSET_DATE_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_DATE_OPS, false), OFFSET_ID };
const ISO_OFFSET_TIME_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_TIME_OPS, false), OFFSET_ID };
const OPT_OFFSET = [_]Op{OFFSET_ID};
const ISO_DATE_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_DATE_OPS, false), comp(&OPT_OFFSET, true) };
const ISO_TIME_OPS = [_]Op{ .{ .case_sensitive = false }, comp(&ISO_LOCAL_TIME_OPS, false), comp(&OPT_OFFSET, true) };
const REGION_TAIL = [_]Op{ .{ .literal = "[" }, .{ .case_sensitive = true }, .zone_region_id, .{ .literal = "]" } };
const ZONED_TAIL = [_]Op{ OFFSET_ID, comp(&REGION_TAIL, true) };
const ISO_DATE_TIME_OPS = [_]Op{ comp(&ISO_LOCAL_DATE_TIME_OPS, false), comp(&ZONED_TAIL, true) };
const ISO_ORDINAL_DATE_OPS = [_]Op{ .{ .case_sensitive = false }, isoValue(.year, 4, 10, .exceeds_pad), .{ .literal = "-" }, isoFixed(.day_of_year, 3), comp(&OPT_OFFSET, true) };
const BASIC_OFFSET = [_]Op{ .{ .strict = false }, .{ .offset = .{ .pattern = 5, .no_offset_text = "Z" } }, .{ .strict = true } };
const BASIC_ISO_DATE_OPS = [_]Op{
    .{ .case_sensitive = false },
    .{ .value = .{ .field = .year, .min = 4, .max = 4, .sign = .not_negative, .subsequent = 4 } },
    .{ .value = .{ .field = .month_of_year, .min = 2, .max = 2, .sign = .not_negative, .subsequent = -1 } },
    .{ .value = .{ .field = .day_of_month, .min = 2, .max = 2, .sign = .not_negative, .subsequent = -1 } },
    comp(&BASIC_OFFSET, true),
};
const ISO_INSTANT_OPS = [_]Op{ .{ .case_sensitive = false }, .instant };

/// The `DateTimeFormatter/ISO_*` constants (all STRICT, no zone), in the
/// static-field index order the surface declares.
pub const ISO_CONSTANTS = [_]struct { name: []const u8, ops: []const Op }{
    .{ .name = "ISO_LOCAL_DATE", .ops = &ISO_LOCAL_DATE_OPS },
    .{ .name = "ISO_LOCAL_TIME", .ops = &ISO_LOCAL_TIME_OPS },
    .{ .name = "ISO_LOCAL_DATE_TIME", .ops = &ISO_LOCAL_DATE_TIME_OPS },
    .{ .name = "ISO_OFFSET_DATE_TIME", .ops = &ISO_OFFSET_DATE_TIME_OPS },
    .{ .name = "ISO_OFFSET_DATE", .ops = &ISO_OFFSET_DATE_OPS },
    .{ .name = "ISO_OFFSET_TIME", .ops = &ISO_OFFSET_TIME_OPS },
    .{ .name = "ISO_DATE", .ops = &ISO_DATE_OPS },
    .{ .name = "ISO_TIME", .ops = &ISO_TIME_OPS },
    .{ .name = "ISO_DATE_TIME", .ops = &ISO_DATE_TIME_OPS },
    .{ .name = "ISO_ORDINAL_DATE", .ops = &ISO_ORDINAL_DATE_OPS },
    .{ .name = "BASIC_ISO_DATE", .ops = &BASIC_ISO_DATE_OPS },
    .{ .name = "ISO_INSTANT", .ops = &ISO_INSTANT_OPS },
};

/// The `ISO_CONSTANTS` index of `name` (comptime: a typo is a build error).
pub fn isoIndex(comptime name: []const u8) u8 {
    inline for (ISO_CONSTANTS, 0..) |c, i| {
        if (comptime std.mem.eql(u8, c.name, name)) return i;
    }
    @compileError("no ISO constant " ++ name);
}

/// ISO constant `idx` as a borrowed (static, never freed) program.
pub fn isoStatic(idx: u8) Program {
    return ISO_PROGRAMS[idx];
}

/// The ISO constants as static programs (STRICT, no zone): the interned
/// `DateTimeFormatter/ISO_*` instances point here and never free them.
pub const ISO_PROGRAMS = build: {
    var arr: [ISO_CONSTANTS.len]Program = undefined;
    for (&arr, ISO_CONSTANTS) |*p, c| p.* = .{ .ops = c.ops, .resolver = .strict };
    break :build arr;
};

// --- tests ---

const testing = std.testing;

fn formatToString(gpa: Allocator, p: *const Program, t: Temporal) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var diag: Diag = .{};
    try format(gpa, p, &t, &out, &diag);
    return out.toOwnedSlice(gpa);
}

test "ofPattern compiles to the JVM toString form" {
    const gpa = testing.allocator;
    var diag: Diag = .{};
    const p = try compilePattern(gpa, "yyyy-MM-dd'T'HH:mm:ss.SSSXXX", &diag);
    defer p.destroy(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try writeProgram(&out, gpa, p);
    try testing.expectEqualStrings("Value(YearOfEra,4,19,EXCEEDS_PAD)'-'Value(MonthOfYear,2)'-'Value(DayOfMonth,2)'T'Value(HourOfDay,2)':'Value(MinuteOfHour,2)':'Value(SecondOfMinute,2)'.'Fraction(NanoOfSecond,3,3)Offset(+HH:MM,'Z')", out.items);
    try testing.expectError(error.DateTime, compilePattern(gpa, "bogus{", &diag));
    try testing.expectEqualStrings("Unknown pattern letter: b", diag.msg());
}

test "format: local date patterns and the optional section" {
    const gpa = testing.allocator;
    var diag: Diag = .{};
    const ed = instant.daysFromCivil(2024, 3, 9);
    const p = try compilePattern(gpa, "EEEE, MMMM dd yy D['T'HH]", &diag);
    defer p.destroy(gpa);
    const s = try formatToString(gpa, p, .{ .date = ed });
    defer gpa.free(s);
    try testing.expectEqualStrings("Saturday, March 09 24 69", s);
}

test "parse + resolve: ISO_OFFSET_DATE_TIME to an instant" {
    const gpa = testing.allocator;
    _ = gpa;
    const p = isoStatic(isoIndex("ISO_OFFSET_DATE_TIME"));
    var diag: Diag = .{};
    var failure: ParseFailure = undefined;
    const parsed = try parse(&p, "2024-01-01T10:00:00+02:00", &diag, &failure);
    try testing.expectEqual(@as(?i64, 1_704_096_000), parsed.fields.get(.instant_seconds));
    try testing.expectError(error.Parse, parse(&p, "2024-01-01T10:00:00+02:00x", &diag, &failure));
    try testing.expectEqual(ParseFailure{ .unparsed = 25 }, failure);
}

test "parse: adjacent value parsing splits yyyyMMdd" {
    const gpa = testing.allocator;
    var diag: Diag = .{};
    const p = try compilePattern(gpa, "yyyyMMdd", &diag);
    defer p.destroy(gpa);
    var failure: ParseFailure = undefined;
    const parsed = try parse(p, "20240309", &diag, &failure);
    try testing.expectEqual(@as(?i64, instant.daysFromCivil(2024, 3, 9)), parsed.date);
}
