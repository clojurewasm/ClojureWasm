// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.LocalDate`.
//!
//! Backend: impl-only
//! Impl deps: instant, local_date
//! Clojure peer: none
//!
//! Java 8+ timezone-agnostic calendar date. The static factories (of / now /
//! parse) populate `method_table` via the `init` callback (D-462) and mint a
//! `.typed_instance` LocalDate VALUE (`runtime/time/local_date_value.zig`)
//! whose per-Runtime descriptor carries the instance methods (getYear /
//! getMonthValue / getDayOfMonth / plusDays). The civil↔epoch-day conversions
//! + the date parser are reused from the sibling `runtime/time/instant.zig`
//! (F-009 neutral home).
//!
//! method_table is populated in `initLocalDate` (runtime) rather than at
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
const ld_value = @import("../../time/local_date_value.zig");
const string_collection = @import("../../collection/string.zig");

const MS_PER_DAY: i64 = 86_400_000;

/// `(java.time.LocalDate/of y m d)` — JVM `LocalDate.of`. All args integers.
fn of(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/of", args, 3, loc);
    for (args) |a| {
        if (a.tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.LocalDate/of", .expected = "integer", .actual = @tagName(a.tag()) });
    }
    return ld_value.make(rt, instant.daysFromCivil(args[0].asInteger(), args[1].asInteger(), args[2].asInteger()));
}

/// `(java.time.LocalDate/now)` — the current wall-clock date. cljw has no zone
/// DB, so this is UTC (clj's LocalDate.now() is local-zone). The e2e does not
/// assert now's exact value, only that it is callable.
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    return ld_value.make(rt, @divFloor(ms, MS_PER_DAY));
}

/// `(java.time.LocalDate/parse s)` — parse an ISO local date `yyyy-MM-dd`. JVM
/// throws `DateTimeParseException`; cljw raises the same `inst_string_invalid`
/// the `#inst` reader uses.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.LocalDate/parse", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.LocalDate/parse", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const epoch_day = instant.parseLocalDate(s) catch
        return error_catalog.raise(.inst_string_invalid, loc, .{ .s = s });
    return ld_value.make(rt, epoch_day);
}

fn initLocalDate(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (LocalDate values point at it). Sentinel-guarded appends keep
    // both registration orders idempotent.
    if (td.lookupMethod(null, "of") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "of", &of },
            .{ "now", &now },
            .{ "parse", &parse },
        });
    }
    td.temporal_print = .iso_local_date;
    try ld_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.LocalDate",
    .descriptor = &descriptor,
    .init = &initLocalDate,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = ld_value.FQCN, // "java.time.LocalDate" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_local_date,
};
