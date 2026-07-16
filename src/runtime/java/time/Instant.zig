// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.Instant`.
//!
//! Backend: impl-only
//! Impl deps: instant
//! Clojure peer: none (clojure.instant has its own parser)
//!
//! Java 8+ canonical time class. The static factories (now / ofEpochSecond /
//! ofEpochMilli / parse) populate `method_table` via the `init` callback (D-462)
//! and mint a `.typed_instance` Instant VALUE (`runtime/time/instant_value.zig`)
//! whose per-Runtime descriptor carries the instance methods
//! (getEpochSecond / getNano / toEpochMilli). The parse/format impl lives in the
//! sibling `runtime/time/instant.zig` (F-009 neutral home).
//!
//! method_table is populated in `initInstant` (runtime) rather than at module
//! scope because `Value.initBuiltinFn(&fn)` calls `@intFromPtr(&fn)` which is
//! not comptime-known on Mac targets in Zig 0.16.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const instant = @import("../../time/instant.zig");
const instant_value = @import("../../time/instant_value.zig");
const string_collection = @import("../../collection/string.zig");

/// Mint an Instant from a whole-second epoch + a nanos fraction. Shared by
/// `ofEpochSecond` (1- and 2-arg) and the milli/parse/now factories. Stores the
/// epoch second-aligned (× 1000) so the value layer + ISO printer line up with
/// Timestamp's convention; `nanos` carries the full sub-second fraction.
fn fromSecondNanos(rt: *Runtime, secs: i64, nanos: i32) anyerror!Value {
    return instant_value.make(rt, secs * 1000, nanos);
}

/// `(java.time.Instant/now)` — the current wall-clock instant (millisecond
/// resolution; JVM `Instant.now()`).
fn now(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Instant/now", args, 0, loc);
    const ms = instant.nowEpochMillis(rt.io);
    return fromSecondNanos(rt, @divFloor(ms, 1000), @intCast(@rem(@rem(ms, 1000) + 1000, 1000) * 1_000_000));
}

/// `(java.time.Instant/ofEpochSecond secs)` / `(… secs nanos)` — JVM
/// `Instant.ofEpochSecond`. The 2-arg form adds the explicit nanosecond
/// fraction; the 1-arg form is whole seconds.
fn ofEpochSecond(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.Instant/ofEpochSecond", args, 1, 2, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.Instant/ofEpochSecond", .expected = "integer", .actual = @tagName(args[0].tag()) });
    const secs = args[0].asInteger();
    var nanos: i32 = 0;
    if (args.len == 2) {
        if (args[1].tag() != .integer)
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.Instant/ofEpochSecond", .expected = "integer", .actual = @tagName(args[1].tag()) });
        nanos = @intCast(args[1].asInteger());
    }
    return fromSecondNanos(rt, secs, nanos);
}

/// `(java.time.Instant/ofEpochMilli ms)` — JVM `Instant.ofEpochMilli`: the
/// whole-second part is the second, the millisecond remainder becomes nanos.
fn ofEpochMilli(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Instant/ofEpochMilli", args, 1, loc);
    if (args[0].tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.time.Instant/ofEpochMilli", .expected = "integer", .actual = @tagName(args[0].tag()) });
    const ms = args[0].asInteger();
    const secs = @divFloor(ms, 1000);
    const nanos: i32 = @intCast(@rem(@rem(ms, 1000) + 1000, 1000) * 1_000_000);
    return fromSecondNanos(rt, secs, nanos);
}

/// `(java.time.Instant/parse s)` — parse an ISO-8601 instant string. Shares the
/// `instant.parseInstantFields` grammar with `#inst` / Date (F-009). JVM throws
/// `DateTimeParseException`; cljw raises the same `instant_string_invalid` the
/// `#inst` reader uses.
fn parse(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Instant/parse", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.time.Instant/parse", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const fields = instant.parseInstantFields(s) catch
        return error_catalog.raise(.inst_string_invalid, loc, .{ .s = s });
    // `epoch_ms` folds the offset + ms; re-split to second-aligned + full nanos.
    return instant_value.make(rt, @divFloor(fields.epoch_ms, 1000) * 1000, fields.nanos);
}

fn initInstant(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    // ADR-0174 merge: ONE descriptor carries the statics AND the instance
    // methods (Instant values point at it). Sentinel-guarded appends keep
    // both registration orders idempotent.
    if (td.lookupMethod(null, "now") == null) {
        try type_descriptor.appendMethodEntries(td, gpa, .{
            .{ "now", &now },
            .{ "ofEpochSecond", &ofEpochSecond },
            .{ "ofEpochMilli", &ofEpochMilli },
            .{ "parse", &parse },
        });
    }
    td.temporal_print = .iso_instant;
    try instant_value.ensureInstanceMethods(td, gpa);
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.Instant",
    .descriptor = &descriptor,
    .init = &initInstant,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = instant_value.FQCN, // "java.time.Instant" — the ONE canonical key (ADR-0174)
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .temporal_print = .iso_instant,
};
