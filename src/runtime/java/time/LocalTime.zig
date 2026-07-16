// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalTime`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_time
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic time-of-day. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalTime VALUE (`runtime/time/local_time_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getHour /
//! getMinute / getSecond / getNano). The time parser is reused from the sibling
//! `runtime/time/instant.zig` (F-009 neutral home).
//!
//! method_table is populated in `initLocalTime` (runtime) rather than at
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
const lt_value = @import("../../time/local_time_value.zig");
const string_collection = @import("../../collection/string.zig");

const MS_PER_DAY: i64 = 86_400_000;
const NANO_PER_SECOND: i64 = 1_000_000_000;

/// Build the `nano_of_day` from h/mi/s/n (all already validated in range).
fn nanoOfDay(h: i64, mi: i64, s: i64, n: i64) i64 {
    return ((h * 60 + mi) * 60 + s) * NANO_PER_SECOND + n;
}

/// `(java.time.LocalTime/of h mi)` / `(… s)` / `(… s n)` — JVM `LocalTime.of`.
/// Arity 2-4: missing second / nano default to 0. All args are integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.LocalTime/of", args, 2, 4, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalTime/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    const h = args[0].asInteger();
    const mi = args[1].asInteger();
    const s = if (args.len >= 3) args[2].asInteger() else 0;
    const n = if (args.len >= 4) args[3].asInteger() else 0;
    return lt_value.make(rt, nanoOfDay(h, mi, s, n));
}

/// `(java.time.LocalTime/now)` — the current wall-clock time-of-day. cljw has
/// no zone DB, so this is UTC (clj's LocalTime.now() is local-zone). The e2e
/// does not assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    return lt_value.make(rt, @mod(ms, MS_PER_DAY) * 1_000_000);
}

/// `(java.time.LocalTime/parse s)` — parse an ISO local time
/// `HH:mm[:ss[.fraction]]`. JVM throws `DateTimeParseException`; cljw raises the
/// same `inst_string_invalid` the `#inst` reader uses.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalTime/parse", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.LocalTime/parse", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const nod = instant.parseLocalTime(s) catch
        return error_catalog.raise(.inst_string_invalid, loc, .{ .s = s });
    return lt_value.make(rt, nod);
}

fn initLocalTime(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalTime values point at it). Sentinel-guarded appends keep
    // both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
        });
    }
    td.temporal_print = .iso_local_time;
    try lt_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalTime",
    .descriptor = &descriptor,
    .init = &initLocalTime,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = lt_value.FQCN, // "java.time.LocalTime" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_time,
};
