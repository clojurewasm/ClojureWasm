// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.time.Duration`.
//!
//! Backend: impl-only
//! Impl deps: time
//! Clojure peer: none
//!
//! Java 8+ time-span class. The static factories (ofSeconds / ofMillis /
//! ofNanos / ofMinutes / ofHours / ofDays) populate `method_table` via the
//! `init` callback (D-462) and mint a `.typed_instance` Duration VALUE
//! (`runtime/time/duration_value.zig`) whose per-Runtime descriptor carries the
//! instance methods (getSeconds / getNano / toMillis / toMinutes). The value is
//! NORMALIZED here (nanos∈[0,1e9), seconds carries the sign); the PT-format
//! toString lives in the value layer.
//!
//! method_table is populated in `initDuration` (runtime) rather than at module
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
const duration_value = @import("../../time/duration_value.zig");

const NANOS_PER_SEC: i64 = 1_000_000_000;

/// Read an integer arg or raise `type_arg_invalid` against `fn_name`.
fn intArg(arg: Value, fn_name: []const u8, loc: SourceLocation) anyerror!i64 {
    if (arg.tag() != .integer)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "integer", .actual = @tagName(arg.tag()) });
    return arg.asInteger();
}

/// `(java.time.Duration/ofSeconds secs)` / `(… secs nanoAdj)` — JVM
/// `Duration.ofSeconds`. The 2-arg form folds an arbitrary nanosecond
/// adjustment into the normalized span (nanos∈[0,1e9), seconds carries sign).
fn ofSeconds(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("java.time.Duration/ofSeconds", args, 1, 2, loc);
    const secs = try intArg(args[0], "java.time.Duration/ofSeconds", loc);
    if (args.len == 1) return duration_value.make(rt, secs, 0);
    const nano_adj = try intArg(args[1], "java.time.Duration/ofSeconds", loc);
    const out_secs = secs + @divFloor(nano_adj, NANOS_PER_SEC);
    const out_nanos: i32 = @intCast(@mod(nano_adj, NANOS_PER_SEC));
    return duration_value.make(rt, out_secs, out_nanos);
}

/// `(java.time.Duration/ofMillis ms)` — JVM `Duration.ofMillis`: the whole
/// seconds + the millisecond remainder as nanos, floored so a negative ms
/// normalizes (e.g. -1500 → {-2, 500000000}).
fn ofMillis(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Duration/ofMillis", args, 1, loc);
    const ms = try intArg(args[0], "java.time.Duration/ofMillis", loc);
    const secs = @divFloor(ms, 1000);
    const nanos: i32 = @intCast(@mod(ms, 1000) * 1_000_000);
    return duration_value.make(rt, secs, nanos);
}

/// `(java.time.Duration/ofNanos n)` — JVM `Duration.ofNanos`: floored
/// normalization into {seconds, nanos∈[0,1e9)}.
fn ofNanos(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Duration/ofNanos", args, 1, loc);
    const n = try intArg(args[0], "java.time.Duration/ofNanos", loc);
    const secs = @divFloor(n, NANOS_PER_SEC);
    const nanos: i32 = @intCast(@mod(n, NANOS_PER_SEC));
    return duration_value.make(rt, secs, nanos);
}

/// `(java.time.Duration/ofMinutes m)` — JVM `Duration.ofMinutes`: m × 60 s.
fn ofMinutes(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Duration/ofMinutes", args, 1, loc);
    const m = try intArg(args[0], "java.time.Duration/ofMinutes", loc);
    return duration_value.make(rt, m * 60, 0);
}

/// `(java.time.Duration/ofHours h)` — JVM `Duration.ofHours`: h × 3600 s.
fn ofHours(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Duration/ofHours", args, 1, loc);
    const h = try intArg(args[0], "java.time.Duration/ofHours", loc);
    return duration_value.make(rt, h * 3600, 0);
}

/// `(java.time.Duration/ofDays d)` — JVM `Duration.ofDays`: d × 86400 s.
fn ofDays(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.time.Duration/ofDays", args, 1, loc);
    const d = try intArg(args[0], "java.time.Duration/ofDays", loc);
    return duration_value.make(rt, d * 86400, 0);
}

fn initDuration(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "ofSeconds", &ofSeconds },
        .{ "ofMillis", &ofMillis },
        .{ "ofNanos", &ofNanos },
        .{ "ofMinutes", &ofMinutes },
        .{ "ofHours", &ofHours },
        .{ "ofDays", &ofDays },
    };
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, specs.len);
    inline for (specs, 0..) |spec, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, spec[0]),
            .method_val = Value.initBuiltinFn(spec[1]),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.time.Duration",
    .descriptor = &descriptor,
    .init = &initDuration,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.time.Duration",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
