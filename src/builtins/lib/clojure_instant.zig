// Copyright (c) 2026 chaploud. All rights reserved.
// SPDX-License-Identifier: EPL-1.0

//! clojure.instant — Date/time parsing API.
//! Replaces clojure/instant.clj.
//! CLJW: Only read-instant-date supported (no Calendar/Timestamp).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const errmod = @import("../../runtime/error.zig");
const bootstrap = @import("../../runtime/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const registry = @import("../registry.zig");
const NamespaceDef = registry.NamespaceDef;

// ============================================================
// Implementation
// ============================================================

fn callCore(allocator: Allocator, name: []const u8, args: []const Value) !Value {
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const core_ns = env.findNamespace("clojure.core") orelse return error.EvalError;
    const v = core_ns.mappings.get(name) orelse return error.EvalError;
    return bootstrap.callFnVal(allocator, v.deref(), args);
}

/// RFC3339 timestamp regex pattern.
const timestamp_pattern = "(\\d\\d\\d\\d)(?:-(\\d\\d)(?:-(\\d\\d)(?:[T](\\d\\d)(?::(\\d\\d)(?::(\\d\\d)(?:[.](\\d+))?)?)?)?)?)?(?:[Z]|([-+])(\\d\\d):(\\d\\d))?";

fn parseInt(s: Value) !i64 {
    if (s.tag() != .string) return error.EvalError;
    return std.fmt.parseInt(i64, s.asString(), 10) catch return error.EvalError;
}

fn zeroFillRight(allocator: Allocator, s: []const u8, width: usize) ![]const u8 {
    if (s.len == width) return s;
    if (s.len > width) return s[0..width];
    const buf = try allocator.alloc(u8, width);
    @memcpy(buf[0..s.len], s);
    @memset(buf[s.len..], '0');
    return buf;
}

fn leapYear(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(month: i64, is_leap: bool) i64 {
    const dim_norm = [_]i64{ 0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const dim_leap = [_]i64{ 0, 31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const idx: usize = @intCast(month);
    if (idx < 1 or idx > 12) return 31;
    return if (is_leap) dim_leap[idx] else dim_norm[idx];
}

const TimestampComponents = struct {
    years: i64,
    months: i64,
    days: i64,
    hours: i64,
    minutes: i64,
    seconds: i64,
    nanoseconds: i64,
    offset_sign: i64,
    offset_hours: i64,
    offset_minutes: i64,
};

fn parseComponents(allocator: Allocator, cs: Value) !?TimestampComponents {
    const pattern_val = try callCore(allocator, "re-pattern", &.{Value.initString(allocator, @constCast(timestamp_pattern))});
    const match_result = try callCore(allocator, "re-matches", &.{ pattern_val, cs });

    if (match_result.tag() == .nil) return null;

    const get = struct {
        fn f(alloc: Allocator, vec: Value, idx: usize) !Value {
            return callCore(alloc, "nth", &.{ vec, Value.initInteger(@intCast(idx)) });
        }
    }.f;

    const fraction_s = try get(allocator, match_result, 7);
    const offset_sign_s = try get(allocator, match_result, 8);
    const months_s = try get(allocator, match_result, 2);
    const days_s = try get(allocator, match_result, 3);
    const hours_s = try get(allocator, match_result, 4);
    const minutes_s = try get(allocator, match_result, 5);
    const seconds_s = try get(allocator, match_result, 6);
    const offset_hours_s = try get(allocator, match_result, 9);
    const offset_minutes_s = try get(allocator, match_result, 10);

    return .{
        .years = try parseInt(try get(allocator, match_result, 1)),
        .months = if (months_s.tag() == .nil) 1 else try parseInt(months_s),
        .days = if (days_s.tag() == .nil) 1 else try parseInt(days_s),
        .hours = if (hours_s.tag() == .nil) 0 else try parseInt(hours_s),
        .minutes = if (minutes_s.tag() == .nil) 0 else try parseInt(minutes_s),
        .seconds = if (seconds_s.tag() == .nil) 0 else try parseInt(seconds_s),
        .nanoseconds = if (fraction_s.tag() == .nil) 0 else blk: {
            const filled = try zeroFillRight(allocator, fraction_s.asString(), 9);
            break :blk std.fmt.parseInt(i64, filled, 10) catch 0;
        },
        .offset_sign = if (offset_sign_s.tag() == .nil) 0 else blk: {
            break :blk if (std.mem.eql(u8, offset_sign_s.asString(), "-")) @as(i64, -1) else 1;
        },
        .offset_hours = if (offset_hours_s.tag() == .nil) 0 else try parseInt(offset_hours_s),
        .offset_minutes = if (offset_minutes_s.tag() == .nil) 0 else try parseInt(offset_minutes_s),
    };
}

fn validateComponents(c: TimestampComponents) !void {
    if (c.months < 1 or c.months > 12)
        return setFail("failed: (<= 1 months 12)");
    if (c.days < 1 or c.days > daysInMonth(c.months, leapYear(c.years)))
        return setFail("failed: (<= 1 days (days-in-month months (leap-year? years)))");
    if (c.hours < 0 or c.hours > 23)
        return setFail("failed: (<= 0 hours 23)");
    if (c.minutes < 0 or c.minutes > 59)
        return setFail("failed: (<= 0 minutes 59)");
    const max_sec: i64 = if (c.minutes == 59) 60 else 59;
    if (c.seconds < 0 or c.seconds > max_sec)
        return setFail("failed: (<= 0 seconds (if (= minutes 59) 60 59))");
    if (c.nanoseconds < 0 or c.nanoseconds > 999_999_999)
        return setFail("failed: (<= 0 nanoseconds 999999999)");
    if (c.offset_sign < -1 or c.offset_sign > 1)
        return setFail("failed: (<= -1 offset-sign 1)");
    if (c.offset_hours < 0 or c.offset_hours > 23)
        return setFail("failed: (<= 0 offset-hours 23)");
    if (c.offset_minutes < 0 or c.offset_minutes > 59)
        return setFail("failed: (<= 0 offset-minutes 59)");
}

fn setFail(msg: []const u8) anyerror!void {
    errmod.setInfoFmt(.eval, .value_error, .{}, "{s}", .{msg});
    return error.EvalError;
}

fn constructDateFromComponents(allocator: Allocator, c: TimestampComponents) !Value {
    const ms = @divTrunc(c.nanoseconds, 1_000_000);

    var offset_buf: [8]u8 = undefined;
    const offset_str: []const u8 = if (c.offset_sign == 0 and c.offset_hours == 0 and c.offset_minutes == 0)
        "Z"
    else blk: {
        const sign_char: u8 = if (c.offset_sign < 0) '-' else '+';
        const oh: u64 = @intCast(c.offset_hours);
        const om: u64 = @intCast(c.offset_minutes);
        break :blk std.fmt.bufPrint(&offset_buf, "{c}{d:0>2}:{d:0>2}", .{ sign_char, oh, om }) catch return error.EvalError;
    };

    var buf: [64]u8 = undefined;
    const y: u64 = @intCast(c.years);
    const mo: u64 = @intCast(c.months);
    const d: u64 = @intCast(c.days);
    const h: u64 = @intCast(c.hours);
    const mi: u64 = @intCast(c.minutes);
    const s: u64 = @intCast(c.seconds);

    const ts = if (ms > 0) blk: {
        const ms_u: u64 = @intCast(ms);
        break :blk std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}", .{ y, mo, d, h, mi, s, ms_u, offset_str }) catch return error.EvalError;
    } else std.fmt.bufPrint(&buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}", .{ y, mo, d, h, mi, s, offset_str }) catch return error.EvalError;

    const ts_val = Value.initString(allocator, try allocator.dupe(u8, ts));
    return callCore(allocator, "__inst-from-string", &.{ts_val});
}

fn componentsToArgs(c: TimestampComponents) [10]Value {
    return .{
        Value.initInteger(c.years),
        Value.initInteger(c.months),
        Value.initInteger(c.days),
        Value.initInteger(c.hours),
        Value.initInteger(c.minutes),
        Value.initInteger(c.seconds),
        Value.initInteger(c.nanoseconds),
        Value.initInteger(c.offset_sign),
        Value.initInteger(c.offset_hours),
        Value.initInteger(c.offset_minutes),
    };
}

/// (parse-timestamp new-instant cs)
fn parseTimestampFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 2) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to parse-timestamp", .{args.len});
    const new_instant = args[0];
    const cs = args[1];
    if (cs.tag() != .string) return errmod.setErrorFmt(.eval, .value_error, .{}, "parse-timestamp expects a string", .{});

    const components = try parseComponents(allocator, cs) orelse {
        return errmod.setErrorFmt(.eval, .value_error, .{}, "Unrecognized date/time syntax: {s}", .{cs.asString()});
    };

    const fn_args = componentsToArgs(components);
    return bootstrap.callFnVal(allocator, new_instant, &fn_args);
}

fn validatedCallFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 11) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to validated-call", .{args.len});
    const constructor = args[0];
    const c = TimestampComponents{
        .years = args[1].asInteger(),
        .months = args[2].asInteger(),
        .days = args[3].asInteger(),
        .hours = args[4].asInteger(),
        .minutes = args[5].asInteger(),
        .seconds = args[6].asInteger(),
        .nanoseconds = args[7].asInteger(),
        .offset_sign = args[8].asInteger(),
        .offset_hours = args[9].asInteger(),
        .offset_minutes = args[10].asInteger(),
    };
    try validateComponents(c);
    const fn_args = componentsToArgs(c);
    return bootstrap.callFnVal(allocator, constructor, &fn_args);
}

/// (validated new-instance) — returns a fn that validates args then calls new-instance.
fn validatedFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to validated", .{args.len});
    const env = dispatch.macro_eval_env orelse return error.EvalError;
    const instant_ns = env.findNamespace("clojure.instant") orelse return error.EvalError;
    const vc_var = instant_ns.mappings.get("__validated-call") orelse return error.EvalError;
    return callCore(allocator, "partial", &.{ vc_var.deref(), args[0] });
}

/// (read-instant-date cs) — parse + validate + construct date.
fn readInstantDateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return errmod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to read-instant-date", .{args.len});
    const cs = args[0];
    if (cs.tag() != .string) return errmod.setErrorFmt(.eval, .value_error, .{}, "read-instant-date expects a string", .{});

    const components = try parseComponents(allocator, cs) orelse {
        return errmod.setErrorFmt(.eval, .value_error, .{}, "Unrecognized date/time syntax: {s}", .{cs.asString()});
    };

    try validateComponents(components);
    return constructDateFromComponents(allocator, components);
}

// ============================================================
// Namespace definition
// ============================================================

const builtins = [_]BuiltinDef{
    .{ .name = "parse-timestamp", .func = &parseTimestampFn, .doc = "Parse a string containing an RFC3339-like timestamp." },
    .{ .name = "validated", .func = &validatedFn, .doc = "Return a function which validates args before calling constructor." },
    .{ .name = "read-instant-date", .func = &readInstantDateFn, .doc = "To read an instant as a date, bind *data-readers* to a map with this var as the value for the 'inst key." },
    .{ .name = "__validated-call", .func = &validatedCallFn, .doc = "Internal: validated constructor dispatcher." },
};

pub const namespace_def = NamespaceDef{
    .name = "clojure.instant",
    .builtins = &builtins,
};
