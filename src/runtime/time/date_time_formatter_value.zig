// SPDX-License-Identifier: EPL-2.0
//! The Value layer of `java.time.format`: `DateTimeFormatter`,
//! `DateTimeFormatterBuilder` and the parse result `java.time.format.Parsed`
//! as `.host_instance` values, plus the `TemporalAccessor` bridge every
//! java.time `from` / `parse(text, formatter)` / `format` goes through.
//!
//! Each instance holds one heap object of the rt-free engine
//! (`date_time_format.zig`) in `state[0]`, allocated on `rt.gc.infra` and
//! freed by the descriptor's `host_finalise` hook: a formatter owns an
//! immutable `Program` (`withZone` copies it), a builder owns its mutable
//! `Builder` (each `append…` mutates it and returns the same instance, like the
//! JVM's fluent builder), a Parsed owns its resolved field set.
//!
//! An engine `Diag` maps onto the error catalog here, so the JVM exception
//! class survives (`DateTimeParseException`, `UnsupportedTemporalTypeException`,
//! `DateTimeException`, `IllegalArgumentException`).

const std = @import("std");
const Value = @import("../value/value.zig").Value;
const HeapHeader = @import("../value/value.zig").HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const Env = @import("../env.zig").Env;
const td_mod = @import("../type_descriptor.zig");
const TypeDescriptor = td_mod.TypeDescriptor;
const TypedInstance = td_mod.TypedInstance;
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const host_instance = @import("../host_instance.zig");
const host_enum = @import("../host_enum.zig");
const string_collection = @import("../collection/string.zig");
const engine = @import("date_time_format.zig");
const zone_offset = @import("zone_offset.zig");
const instant_value = @import("instant_value.zig");
const local_date_value = @import("local_date_value.zig");
const local_time_value = @import("local_time_value.zig");
const local_date_time_value = @import("local_date_time_value.zig");

pub const FORMATTER_FQCN = "java.time.format.DateTimeFormatter";
pub const BUILDER_FQCN = "java.time.format.DateTimeFormatterBuilder";
pub const PARSED_FQCN = "java.time.format.Parsed";

const BuiltinFn = *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value;

// --- host-instance plumbing ---

fn isHostOf(v: Value, fqcn: []const u8) bool {
    if (v.tag() != .host_instance) return false;
    const fq = host_instance.asHostInstance(v).descriptor.fqcn orelse return false;
    return std.mem.eql(u8, fq, fqcn);
}

pub fn isFormatter(v: Value) bool {
    return isHostOf(v, FORMATTER_FQCN);
}

pub fn isParsed(v: Value) bool {
    return isHostOf(v, PARSED_FQCN);
}

fn payload(comptime T: type, v: Value) *T {
    return @ptrFromInt(@as(usize, @intCast(host_instance.asHostInstance(v).state[0])));
}

pub fn programOf(v: Value) *const engine.Program {
    return payload(engine.Program, v);
}

/// The receiver of an instance method, type-checked. `Class/.member` hands out
/// the raw method fn, so args[0] can be any value; reading `state[0]` of a
/// non-instance would dereference garbage.
fn receiver(comptime T: type, v: Value, fqcn: []const u8, method: []const u8, loc: SourceLocation) !*T {
    if (!isHostOf(v, fqcn))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = method, .expected = fqcn, .actual = classNameOf(v) });
    return payload(T, v);
}

fn fmtRecv(v: Value, method: []const u8, loc: SourceLocation) !*const engine.Program {
    return receiver(engine.Program, v, FORMATTER_FQCN, method, loc);
}

fn builderRecv(v: Value, method: []const u8, loc: SourceLocation) !*engine.Builder {
    return receiver(engine.Builder, v, BUILDER_FQCN, method, loc);
}

fn parsedRecv(v: Value, method: []const u8, loc: SourceLocation) !*const engine.Parsed {
    return receiver(engine.Parsed, v, PARSED_FQCN, method, loc);
}

fn parsedOf(v: Value) *const engine.Parsed {
    return payload(engine.Parsed, v);
}

fn finaliseProgram(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    if (state[1] == BORROWED) return; // an interned ISO constant's static program
    const p: *engine.Program = @ptrFromInt(@as(usize, @intCast(state[0])));
    p.destroy(infra);
}

fn finaliseBuilder(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const b: *engine.Builder = @ptrFromInt(@as(usize, @intCast(state[0])));
    b.destroy(infra);
}

fn finaliseParsed(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const p: *engine.Parsed = @ptrFromInt(@as(usize, @intCast(state[0])));
    infra.destroy(p);
}

/// Wrap an owned heap `Program` in a formatter instance (ownership moves).
pub fn wrapProgram(rt: *Runtime, p: *engine.Program) !Value {
    errdefer p.destroy(rt.gc.infra);
    const td = try formatterDescriptor(rt);
    return host_instance.alloc(rt, td, .{ @intFromPtr(p), 0, 0, 0 });
}

fn wrapParsed(rt: *Runtime, parsed: engine.Parsed) !Value {
    const p = try rt.gc.infra.create(engine.Parsed);
    p.* = parsed;
    errdefer rt.gc.infra.destroy(p);
    const td = try td_mod.ensureRegistered(rt, PARSED_FQCN, &configureParsed);
    return host_instance.alloc(rt, td, .{ @intFromPtr(p), 0, 0, 0 });
}

/// A fresh builder instance (the `(DateTimeFormatterBuilder.)` constructor).
pub fn newBuilder(rt: *Runtime) !Value {
    const b = try engine.Builder.create(rt.gc.infra);
    errdefer b.destroy(rt.gc.infra);
    const td = try builderDescriptor(rt);
    return host_instance.alloc(rt, td, .{ @intFromPtr(b), 0, 0, 0 });
}

/// `state[1]` of a formatter whose program is static (never freed).
const BORROWED: u64 = 1;

/// `DateTimeFormatter/ISO_*` constant `idx`: one interned instance per
/// Runtime over the engine's static program (JVM `identical?` parity), on
/// `gc.infra` like the host-enum singletons; freed by `deinitIsoConstants`.
pub fn isoConstant(rt: *Runtime, idx: u8) !Value {
    const slot = &rt.iso_formatters[idx];
    if (!slot.isNil()) return slot.*;
    const td = try formatterDescriptor(rt);
    const inst = try rt.gc.infra.create(host_instance.HostInstance);
    inst.* = .{
        .header = HeapHeader.init(.host_instance),
        .descriptor = td,
        .state = .{ @intFromPtr(&engine.ISO_PROGRAMS[idx]), BORROWED, 0, 0 },
    };
    slot.* = Value.encodeHeapPtr(.host_instance, inst);
    return slot.*;
}

/// Release the interned ISO formatters. Called from `Runtime.deinit`.
pub fn deinitIsoConstants(rt: *Runtime) void {
    for (&rt.iso_formatters) |*slot| {
        if (slot.isNil()) continue;
        rt.gc.infra.destroy(@constCast(host_instance.asHostInstance(slot.*)));
        slot.* = .nil_val;
    }
}

// --- errors ---

/// Raise the catalog error an engine `Diag` describes.
pub fn raiseDiag(diag: *const engine.Diag, loc: SourceLocation) anyerror {
    return switch (diag.kind) {
        .value => error_catalog.raise(.date_time_value_invalid, loc, .{ .detail = diag.msg() }),
        .unsupported_field => error_catalog.raise(.temporal_field_unsupported, loc, .{ .field = diag.field.display() }),
        .pattern => error_catalog.raise(.date_time_pattern_invalid, loc, .{ .detail = diag.msg() }),
        .pattern_letter => error_catalog.raise(.date_time_pattern_letter_unsupported, loc, .{ .letter = diag.msg() }),
        .state => error_catalog.raise(.date_time_builder_state_invalid, loc, .{ .detail = diag.msg() }),
    };
}

/// Map an engine error: OOM passes through, `DateTime` raises its Diag.
fn engineErr(e: engine.Error, diag: *const engine.Diag, loc: SourceLocation) anyerror {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DateTime => raiseDiag(diag, loc),
    };
}

/// The JVM shortens a long input in a parse message to 64 chars + "...".
fn abbreviate(text: []const u8, buf: *[80]u8) []const u8 {
    if (text.len <= 64) return text;
    @memcpy(buf[0..64], text[0..64]);
    @memcpy(buf[64..67], "...");
    return buf[0..67];
}

fn raiseUnparseable(text: []const u8, detail: []const u8, loc: SourceLocation) anyerror {
    var ab: [80]u8 = undefined;
    return error_catalog.raise(.date_time_text_unparseable, loc, .{ .text = abbreviate(text, &ab), .detail = detail });
}

// --- the TemporalAccessor bridge ---

/// The engine view of a TemporalAccessor value, or null when `v` is not one.
pub fn temporalOf(v: Value) ?engine.Temporal {
    if (isParsed(v)) return parsedOf(v).temporal();
    if (v.tag() != .typed_instance) return null;
    if (local_date_value.isLocalDate(v)) return .{ .date = local_date_value.epochDayOf(v) };
    if (local_time_value.isLocalTime(v)) return .{ .time = local_time_value.nanoOfDayOf(v) };
    if (local_date_time_value.isLocalDateTime(v)) return .{ .date = local_date_time_value.epochDayOf(v), .time = local_date_time_value.nanoOfDayOf(v) };
    if (instant_value.isInstant(v)) return .{ .instant_secs = @divFloor(instant_value.epochMsOf(v), 1000), .instant_nanos = instant_value.nanosOf(v) };
    return null;
}

/// The JVM class name of a value, for the "of type …" / ClassCastException text.
pub fn classNameOf(v: Value) []const u8 {
    return switch (v.tag()) {
        .host_instance => host_instance.asHostInstance(v).descriptor.fqcn orelse "java.lang.Object",
        .typed_instance => v.decodePtr(*const TypedInstance).descriptor.fqcn orelse "java.lang.Object",
        .string => "java.lang.String",
        .integer => "java.lang.Long",
        .float => "java.lang.Double",
        .keyword => "clojure.lang.Keyword",
        .nil => "nil",
        else => @tagName(v.tag()),
    };
}

/// The value's toString, for the "Unable to obtain" message.
fn temporalTextOf(rt: *Runtime, v: Value, t: *const engine.Temporal, buf: []u8) ![]const u8 {
    if (isParsed(v)) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(rt.gpa);
        try parsedOf(v).write(&out, rt.gpa);
        const n = @min(out.items.len, buf.len);
        @memcpy(buf[0..n], out.items[0..n]);
        return buf[0..n];
    }
    return engine.temporalText(buf, t);
}

fn requireTemporal(v: Value, loc: SourceLocation) !engine.Temporal {
    return temporalOf(v) orelse error_catalog.raise(.temporal_accessor_expected, loc, .{ .class = classNameOf(v) });
}

fn raiseUnconvertible(rt: *Runtime, target: []const u8, v: Value, t: *const engine.Temporal, loc: SourceLocation) anyerror {
    var tb: [256]u8 = undefined;
    const text = try temporalTextOf(rt, v, t, &tb);
    return error_catalog.raise(.temporal_accessor_unconvertible, loc, .{ .target = target, .temporal = text, .class = classNameOf(v) });
}

/// The four `from` conversions (`LocalDate/from` …).
pub const Target = enum {
    local_date,
    local_time,
    local_date_time,
    instant,

    fn simpleName(self: Target) []const u8 {
        return switch (self) {
            .local_date => "LocalDate",
            .local_time => "LocalTime",
            .local_date_time => "LocalDateTime",
            .instant => "Instant",
        };
    }
};

/// `Target.from(temporal)`: the value, or the JVM DateTimeException.
pub fn convert(rt: *Runtime, target: Target, v: Value, loc: SourceLocation) !Value {
    const t = try requireTemporal(v, loc);
    return convertTemporal(rt, target, v, &t, loc);
}

fn convertTemporal(rt: *Runtime, target: Target, v: Value, t: *const engine.Temporal, loc: SourceLocation) !Value {
    switch (target) {
        .local_date => {
            const ed = t.date orelse return raiseUnconvertible(rt, "LocalDate", v, t, loc);
            return local_date_value.make(rt, ed);
        },
        .local_time => {
            const nod = t.time orelse return raiseUnconvertible(rt, "LocalTime", v, t, loc);
            return local_time_value.make(rt, nod);
        },
        .local_date_time => {
            const ed = t.date orelse return raiseUnconvertible(rt, "LocalDateTime", v, t, loc);
            const nod = t.time orelse return raiseUnconvertible(rt, "LocalDateTime", v, t, loc);
            return local_date_time_value.make(rt, ed, nod);
        },
        .instant => {
            if (instant_value.isInstant(v)) return v;
            const secs = t.getField(.instant_seconds) orelse return raiseUnconvertible(rt, "Instant", v, t, loc);
            const nanos = t.getField(.nano_of_second) orelse return raiseUnconvertible(rt, "Instant", v, t, loc);
            return instant_value.make(rt, secs * 1000, @intCast(nanos));
        },
    }
}

/// `Target.parse(text, formatter)`: parse, then convert; a conversion failure
/// is reworded as the DateTimeParseException the JVM's `parse(text, query)`
/// throws.
pub fn parseTo(rt: *Runtime, target: Target, text_v: Value, fmt_v: Value, fn_name: []const u8, loc: SourceLocation) !Value {
    if (!isFormatter(fmt_v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a DateTimeFormatter", .actual = classNameOf(fmt_v) });
    return parseWith(rt, target, text_v, programOf(fmt_v), fn_name, loc);
}

/// `Target.parse(text)`: the 1-arity form, which the JVM defines as
/// `parse(text, ISO_<target>)`.
pub fn parseIso(rt: *Runtime, target: Target, text_v: Value, comptime iso_name: []const u8, fn_name: []const u8, loc: SourceLocation) !Value {
    const p = engine.isoStatic(engine.isoIndex(iso_name));
    return parseWith(rt, target, text_v, &p, fn_name, loc);
}

fn parseWith(rt: *Runtime, target: Target, text_v: Value, p: *const engine.Program, fn_name: []const u8, loc: SourceLocation) !Value {
    if (text_v.tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(text_v.tag()) });
    const text = string_collection.asString(text_v);
    const parsed = try parseText(p, text, loc);
    const t = parsed.temporal();
    const ok = switch (target) {
        .local_date => t.date != null,
        .local_time => t.time != null,
        .local_date_time => t.date != null and t.time != null,
        .instant => t.getField(.instant_seconds) != null and t.getField(.nano_of_second) != null,
    };
    if (!ok) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(rt.gpa);
        try out.appendSlice(rt.gpa, ": Unable to obtain ");
        try out.appendSlice(rt.gpa, target.simpleName());
        try out.appendSlice(rt.gpa, " from TemporalAccessor: ");
        try parsed.write(&out, rt.gpa);
        try out.appendSlice(rt.gpa, " of type " ++ PARSED_FQCN);
        return raiseUnparseable(text, out.items, loc);
    }
    // `ok` guarantees the conversion succeeds, so no receiver is needed for
    // an error message.
    return convertTemporal(rt, target, .nil_val, &t, loc);
}

/// Run the engine parse, raising the DateTimeParseException on any failure.
fn parseText(p: *const engine.Program, text: []const u8, loc: SourceLocation) !engine.Parsed {
    var diag: engine.Diag = .{};
    var failure: engine.ParseFailure = undefined;
    return engine.parse(p, text, &diag, &failure) catch |e| {
        var db: [300]u8 = undefined;
        const detail = switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Parse => switch (failure) {
                .index => |i| std.fmt.bufPrint(&db, " at index {d}", .{i}) catch unreachable,
                .unparsed => |i| std.fmt.bufPrint(&db, ", unparsed text found at index {d}", .{i}) catch unreachable,
            },
            error.DateTime => std.fmt.bufPrint(&db, ": {s}", .{diag.msg()}) catch db[0..],
        };
        return raiseUnparseable(text, detail, loc);
    };
}

/// Format `v` with `fmt_v` (the shared body of `fmt.format(t)` and
/// `t.format(fmt)`).
pub fn formatValue(rt: *Runtime, fmt_v: Value, v: Value, loc: SourceLocation) !Value {
    const p = programOf(fmt_v);
    var t = try requireTemporal(v, loc);
    if (p.zone) |zone| {
        // The override zone re-projects anything that is an instant; other
        // temporals only gain it for zone-id printing (DateTimePrintContext).
        if (t.instant_secs != null and t.fields == null) {
            t = engine.Temporal.atZone(t.instant_secs.?, t.instant_nanos, zone);
        } else if (t.getField(.instant_seconds)) |secs| {
            t = engine.Temporal.atZone(secs, @intCast(t.getField(.nano_of_second) orelse 0), zone);
        } else {
            t.zone = zone;
        }
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gpa);
    var diag: engine.Diag = .{};
    engine.format(rt.gpa, p, &t, &out, &diag) catch |e| return engineErr(e, &diag, loc);
    return string_collection.alloc(rt, out.items);
}

// --- DateTimeFormatter instance methods ---

fn fmtFormat(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("format", args, 2, loc);
    _ = try fmtRecv(args[0], "format", loc);
    return formatValue(rt, args[0], args[1], loc);
}

/// `(.parse fmt text)` — the resolved `Parsed` TemporalAccessor.
fn fmtParse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("parse", args, 2, loc);
    if (args[1].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "parse", .actual = @tagName(args[1].tag()) });
    const parsed = try parseText(try fmtRecv(args[0], "parse", loc), string_collection.asString(args[1]), loc);
    return wrapParsed(rt, parsed);
}

/// `(.withZone fmt zone)` — a copy carrying the override zone.
fn fmtWithZone(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("withZone", args, 2, loc);
    if (!args[1].isNil() and !zone_offset.isZone(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "withZone", .expected = "a ZoneId", .actual = classNameOf(args[1]) });
    const copy = try (try fmtRecv(args[0], "withZone", loc)).clone(rt.gc.infra);
    copy.zone = if (args[1].isNil()) null else zone_offset.zoneOf(args[1]);
    return wrapProgram(rt, copy);
}

fn fmtGetZone(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getZone", args, 1, loc);
    const zone = (try fmtRecv(args[0], "getZone", loc)).zone orelse return .nil_val;
    return zone_offset.make(rt, zone);
}

fn fmtToString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gpa);
    try engine.writeProgram(&out, rt.gpa, try fmtRecv(args[0], "toString", loc));
    return string_collection.alloc(rt, out.items);
}

/// `(.withLocale fmt locale)`: cljw has one locale (English), so every
/// formatter already is in it; the JVM returns the receiver when the locale
/// is unchanged.
fn fmtWithLocale(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("withLocale", args, 2, loc);
    _ = try fmtRecv(args[0], "withLocale", loc);
    if (!isHostOf(args[1], "java.util.Locale"))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "withLocale", .expected = "a java.util.Locale", .actual = classNameOf(args[1]) });
    return args[0];
}

pub const FORMATTER_METHODS = [_]struct { []const u8, BuiltinFn }{
    .{ "format", &fmtFormat },
    .{ "withLocale", &fmtWithLocale },
    .{ "parse", &fmtParse },
    .{ "withZone", &fmtWithZone },
    .{ "getZone", &fmtGetZone },
    .{ "toString", &fmtToString },
};

pub fn ensureFormatterMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.host_finalise = &finaliseProgram;
    if (td.lookupMethod(null, "format") != null) return;
    try td_mod.appendMethodEntries(td, gpa, FORMATTER_METHODS);
}

fn formatterDescriptor(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, FORMATTER_FQCN, &ensureFormatterMethods);
}

// --- DateTimeFormatterBuilder instance methods ---

fn fieldArg(v: Value, fn_name: []const u8, loc: SourceLocation) !engine.Field {
    if (v.tag() == .host_instance) {
        const hi = host_instance.asHostInstance(v);
        if (hi.descriptor.host_enum_idx) |idx| {
            if (idx == @intFromEnum(host_enum.Idx.chrono_field)) return @enumFromInt(@as(u8, @intCast(hi.state[0])));
        }
    }
    return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a ChronoField", .actual = classNameOf(v) });
}

fn intArg(v: Value, fn_name: []const u8, loc: SourceLocation) !i64 {
    if (v.tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "integer", .actual = @tagName(v.tag()) });
    return v.asInteger();
}

fn stringArg(v: Value, fn_name: []const u8, loc: SourceLocation) ![]const u8 {
    if (v.tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = fn_name, .actual = @tagName(v.tag()) });
    return string_collection.asString(v);
}

fn formatterArg(v: Value, fn_name: []const u8, loc: SourceLocation) !*const engine.Program {
    if (!isFormatter(v))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "a DateTimeFormatter", .actual = classNameOf(v) });
    return programOf(v);
}

/// Run one builder mutation, mapping its Diag; the builder instance is the
/// result (the JVM builder returns `this`).
fn mutated(args: []const Value, r: engine.Error!void, diag: *const engine.Diag, loc: SourceLocation) !Value {
    r catch |e| return engineErr(e, diag, loc);
    return args[0];
}

fn bAppendPattern(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendPattern", args, 2, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendPattern", loc)).appendPattern(rt.gc.infra, try stringArg(args[1], "appendPattern", loc), &diag), &diag, loc);
}

/// `appendValue(field)` / `appendValue(field, width)`. The 4-arity form
/// takes a `SignStyle`, which cljw does not surface.
fn bAppendValue(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("appendValue", args, 2, 3, loc);
    const f = try fieldArg(args[1], "appendValue", loc);
    var diag: engine.Diag = .{};
    const b = (try builderRecv(args[0], "appendValue", loc));
    if (args.len == 2) return mutated(args, b.appendValue(rt.gc.infra, f), &diag, loc);
    return mutated(args, b.appendValueWidth(rt.gc.infra, f, try intArg(args[2], "appendValue", loc), &diag), &diag, loc);
}

fn bAppendFraction(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendFraction", args, 5, loc);
    const f = try fieldArg(args[1], "appendFraction", loc);
    const min = try intArg(args[2], "appendFraction", loc);
    const max = try intArg(args[3], "appendFraction", loc);
    if (args[4].tag() != .boolean)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "appendFraction", .expected = "boolean", .actual = @tagName(args[4].tag()) });
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendFraction", loc)).appendFraction(rt.gc.infra, f, min, max, args[4].asBoolean(), &diag), &diag, loc);
}

/// `appendText(field)` — the FULL text style.
fn bAppendText(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendText", args, 2, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendText", loc)).appendText(rt.gc.infra, try fieldArg(args[1], "appendText", loc), .full), &diag, loc);
}

/// `appendLiteral(char)` / `appendLiteral(String)`.
fn bAppendLiteral(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendLiteral", args, 2, loc);
    var cb: [4]u8 = undefined;
    const s: []const u8 = switch (args[1].tag()) {
        .char => cb[0 .. std.unicode.utf8Encode(args[1].asChar(), &cb) catch 0],
        .string => string_collection.asString(args[1]),
        else => return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "appendLiteral", .expected = "a char or string", .actual = @tagName(args[1].tag()) }),
    };
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendLiteral", loc)).appendLiteral(rt.gc.infra, s), &diag, loc);
}

fn bAppendOffset(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendOffset", args, 3, loc);
    const pattern = try stringArg(args[1], "appendOffset", loc);
    const no_offset = try stringArg(args[2], "appendOffset", loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendOffset", loc)).appendOffset(rt.gc.infra, pattern, no_offset, &diag), &diag, loc);
}

/// `appendOffsetId` = `appendOffset("+HH:MM:ss", "Z")`.
fn bAppendOffsetId(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendOffsetId", args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendOffsetId", loc)).appendOffset(rt.gc.infra, "+HH:MM:ss", "Z", &diag), &diag, loc);
}

fn bAppendZoneId(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendZoneId", args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendZoneId", loc)).append(rt.gc.infra, .zone_id), &diag, loc);
}

/// `appendInstant()` — ISO_INSTANT's printer-parser.
fn bAppendInstant(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendInstant", args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendInstant", loc)).append(rt.gc.infra, .instant), &diag, loc);
}

fn bOptionalStart(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("optionalStart", args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "optionalStart", loc)).optionalStart(rt.gc.infra), &diag, loc);
}

fn bOptionalEnd(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("optionalEnd", args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "optionalEnd", loc)).optionalEnd(rt.gc.infra, &diag), &diag, loc);
}

fn setting(rt: *Runtime, args: []const Value, name: []const u8, op: engine.Op, loc: SourceLocation) !Value {
    try error_catalog.checkArity(name, args, 1, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "optionalEnd", loc)).append(rt.gc.infra, op), &diag, loc);
}

fn bParseCaseInsensitive(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return setting(rt, args, "parseCaseInsensitive", .{ .case_sensitive = false }, loc);
}

fn bParseCaseSensitive(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return setting(rt, args, "parseCaseSensitive", .{ .case_sensitive = true }, loc);
}

fn bParseStrict(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return setting(rt, args, "parseStrict", .{ .strict = true }, loc);
}

fn bParseLenient(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return setting(rt, args, "parseLenient", .{ .strict = false }, loc);
}

fn bParseDefaulting(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("parseDefaulting", args, 3, loc);
    const f = try fieldArg(args[1], "parseDefaulting", loc);
    const v = try intArg(args[2], "parseDefaulting", loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "parseDefaulting", loc)).append(rt.gc.infra, .{ .default_value = .{ .field = f, .value = v } }), &diag, loc);
}

fn bAppend(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("append", args, 2, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "append", loc)).appendProgram(rt.gc.infra, try formatterArg(args[1], "append", loc), false), &diag, loc);
}

fn bAppendOptional(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("appendOptional", args, 2, loc);
    var diag: engine.Diag = .{};
    return mutated(args, (try builderRecv(args[0], "appendOptional", loc)).appendProgram(rt.gc.infra, try formatterArg(args[1], "appendOptional", loc), true), &diag, loc);
}

/// `toFormatter()` / `toFormatter(locale)` (cljw has one locale): SMART.
fn bToFormatter(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("toFormatter", args, 1, 2, loc);
    var diag: engine.Diag = .{};
    const p = (try builderRecv(args[0], "toFormatter", loc)).toProgram(rt.gc.infra, .smart) catch |e| return engineErr(e, &diag, loc);
    return wrapProgram(rt, p);
}

pub const BUILDER_METHODS = [_]struct { []const u8, BuiltinFn }{
    .{ "appendPattern", &bAppendPattern },
    .{ "appendValue", &bAppendValue },
    .{ "appendFraction", &bAppendFraction },
    .{ "appendText", &bAppendText },
    .{ "appendLiteral", &bAppendLiteral },
    .{ "appendOffset", &bAppendOffset },
    .{ "appendOffsetId", &bAppendOffsetId },
    .{ "appendZoneId", &bAppendZoneId },
    .{ "appendInstant", &bAppendInstant },
    .{ "optionalStart", &bOptionalStart },
    .{ "optionalEnd", &bOptionalEnd },
    .{ "parseCaseInsensitive", &bParseCaseInsensitive },
    .{ "parseCaseSensitive", &bParseCaseSensitive },
    .{ "parseStrict", &bParseStrict },
    .{ "parseLenient", &bParseLenient },
    .{ "parseDefaulting", &bParseDefaulting },
    .{ "append", &bAppend },
    .{ "appendOptional", &bAppendOptional },
    .{ "toFormatter", &bToFormatter },
};

pub fn ensureBuilderMethods(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.host_finalise = &finaliseBuilder;
    if (td.lookupMethod(null, "appendPattern") != null) return;
    try td_mod.appendMethodEntries(td, gpa, BUILDER_METHODS);
}

fn builderDescriptor(rt: *Runtime) !*const TypeDescriptor {
    return td_mod.ensureRegistered(rt, BUILDER_FQCN, &ensureBuilderMethods);
}

// --- Parsed instance methods ---

fn parsedGetLong(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getLong", args, 2, loc);
    const f = try fieldArg(args[1], "getLong", loc);
    const t = (try parsedRecv(args[0], "getLong", loc)).temporal();
    const v = t.getField(f) orelse return error_catalog.raise(.temporal_field_unsupported, loc, .{ .field = f.display() });
    return Value.initInteger(v);
}

fn parsedIsSupported(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isSupported", args, 2, loc);
    const f = try fieldArg(args[1], "isSupported", loc);
    return Value.initBoolean((try parsedRecv(args[0], "isSupported", loc)).temporal().getField(f) != null);
}

fn parsedToString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(rt.gpa);
    try (try parsedRecv(args[0], "toString", loc)).write(&out, rt.gpa);
    return string_collection.alloc(rt, out.items);
}

fn configureParsed(td: *TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    td.host_finalise = &finaliseParsed;
    try td_mod.appendMethodEntries(td, gpa, .{
        .{ "getLong", &parsedGetLong },
        .{ "isSupported", &parsedIsSupported },
        .{ "toString", &parsedToString },
    });
}

// --- tests ---

const testing = std.testing;

test "temporalOf: the local types and Instant; non-temporals are null" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    const d = try local_date_value.make(&rt, 19_791);
    try testing.expectEqual(@as(?i64, 19_791), temporalOf(d).?.date);
    const i = try instant_value.make(&rt, 5000, 7);
    try testing.expectEqual(@as(?i64, 5), temporalOf(i).?.instant_secs);
    try testing.expect(temporalOf(Value.initInteger(1)) == null);
}
