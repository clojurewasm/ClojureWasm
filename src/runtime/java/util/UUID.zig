// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.util.UUID`.
//!
//! Backend: impl-only
//! Impl deps: uuid
//! Clojure peer: clojure.core/random-uuid, clojure.core/parse-uuid
//!
//! Thin wrapper over `runtime/uuid.zig` per F-009. The Clojure-ns
//! peer (`lang/primitive/uuid.zig`) calls the same impl; this file
//! is the entry point for `(java.util.UUID/randomUUID)` and similar
//! Java-style static invocations.
//!
//! D-121 + ADR-0050: populates `method_table` for the static method
//! `randomUUID`. Dispatched via `InteropCallNode { .kind =
//! .static_method }`. Return Value is a `.uuid` value (ADR-0074;
//! matches the Clojure-peer `random-uuid` shape).
//!
//! method_table is populated in `initUUID` (runtime) rather than at
//! module scope because `Value.initBuiltinFn(&fn)` calls
//! `@intFromPtr(&fn)` which is not comptime-known on Mac targets in
//! Zig 0.16.

const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const uuid = @import("../../uuid.zig");
const string_collection = @import("../../collection/string.zig");

/// Implements `(java.util.UUID/randomUUID)`.
/// Spec: returns a UUID v4 `.uuid` value (ADR-0074; was a canonical String
/// pre-cycle-3). Matches JVM `java.util.UUID.randomUUID()` returning a UUID
/// instance + `clojure.core/random-uuid`.
/// JVM reference: java.util.UUID#randomUUID (java.base/java/util/UUID.java).
/// cw v1 tier: A (Phase 14 row 14.11 / D-121).
fn randomUUID(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.UUID/randomUUID", args, 0, loc);
    return try uuid.alloc(rt, uuid.generateV4(rt.io));
}

/// Implements `(java.util.UUID/fromString s)` — parse a canonical UUID string
/// to a `.uuid` value. JVM throws IllegalArgumentException on a malformed
/// string; cljw raises `uuid_string_invalid` (same as `#uuid`, AD-007). Shares
/// `uuid.parse` with `parse-uuid` / `#uuid` (F-009). JVM ref: java.util.UUID#
/// fromString.
fn fromString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.UUID/fromString", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.util.UUID/fromString", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const bytes = uuid.parse(s) catch return error_catalog.raise(.uuid_string_invalid, loc, .{ .s = s });
    return try uuid.alloc(rt, bytes);
}

const std = @import("std");

/// `(java.util.UUID. mostSigBits leastSigBits)` — the only public JVM ctor,
/// `UUID(long, long)`. Writes the two 64-bit halves big-endian into the 16-byte
/// representation (msb → bytes[0..8], lsb → bytes[8..16]), the inverse of
/// getMostSignificantBits / getLeastSignificantBits. JVM ref: java.util.UUID#<init>.
fn uuidCtor(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.util.UUID.", args, 2, loc);
    const msb = try error_catalog.expectI64(args[0], "java.util.UUID.", loc);
    const lsb = try error_catalog.expectI64(args[1], "java.util.UUID.", loc);
    var bytes: [16]u8 = undefined;
    std.mem.writeInt(i64, bytes[0..8], msb, .big);
    std.mem.writeInt(i64, bytes[8..16], lsb, .big);
    return try uuid.alloc(rt, bytes);
}

// --- instance methods on a `.uuid` value (D-431 per-class completeness) ---

/// `(.getMostSignificantBits u)` — the high 64 bits as a signed long (JVM).
fn getMostSignificantBits(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getMostSignificantBits", args, 1, loc);
    const b = uuid.asUuid(args[0]).bytes;
    return Value.initInteger(std.mem.readInt(i64, b[0..8], .big));
}

/// `(.getLeastSignificantBits u)` — the low 64 bits as a signed long (JVM).
fn getLeastSignificantBits(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".getLeastSignificantBits", args, 1, loc);
    const b = uuid.asUuid(args[0]).bytes;
    return Value.initInteger(std.mem.readInt(i64, b[8..16], .big));
}

/// `(.version u)` — the version nibble (4 for a v4 UUID). JVM UUID#version.
fn version(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".version", args, 1, loc);
    const b = uuid.asUuid(args[0]).bytes;
    return Value.initInteger((b[6] >> 4) & 0x0F);
}

/// `(.variant u)` — the RFC-4122 variant (2 for a standard UUID). Mirrors JVM
/// UUID#variant's exact bit formula over the least-significant 64 bits.
fn variant(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".variant", args, 1, loc);
    const b = uuid.asUuid(args[0]).bytes;
    const lsb = std.mem.readInt(u64, b[8..16], .big);
    const hi2: u32 = @intCast(lsb >> 62);
    const sh: u6 = @intCast((64 - hi2) & 63); // Java masks the shift to 6 bits
    const shifted = lsb >> sh;
    const mask: u64 = @bitCast(@as(i64, @bitCast(lsb)) >> 63); // arithmetic: 0 or all-1s
    return Value.initInteger(@bitCast(shifted & mask));
}

/// `(.compareTo a b)` — JVM UUID#compareTo: signed compare of msb then lsb,
/// normalised to -1 / 0 / 1.
fn compareTo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity(".compareTo", args, 2, loc);
    if (args[1].tag() != .uuid)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".compareTo", .expected = "uuid", .actual = @tagName(args[1].tag()) });
    const a = uuid.asUuid(args[0]).bytes;
    const c = uuid.asUuid(args[1]).bytes;
    const a_msb = std.mem.readInt(i64, a[0..8], .big);
    const c_msb = std.mem.readInt(i64, c[0..8], .big);
    if (a_msb != c_msb) return Value.initInteger(if (a_msb < c_msb) -1 else 1);
    const a_lsb = std.mem.readInt(i64, a[8..16], .big);
    const c_lsb = std.mem.readInt(i64, c[8..16], .big);
    if (a_lsb != c_lsb) return Value.initInteger(if (a_lsb < c_lsb) -1 else 1);
    return Value.initInteger(0);
}

/// Install the `.uuid`-tag instance methods (bit accessors + version / variant /
/// compareTo). Called from `lang/primitive.zig` at runtime init alongside
/// `String.installNativeMethods` (ADR-0050 am1 caveat 3).
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.uuid);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "getMostSignificantBits", &getMostSignificantBits },
        .{ "getLeastSignificantBits", &getLeastSignificantBits },
        .{ "version", &version },
        .{ "variant", &variant },
        .{ "compareTo", &compareTo },
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

fn initUUID(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, 3);
    entries[0] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "randomUUID"),
        .method_val = Value.initBuiltinFn(&randomUUID),
    };
    entries[1] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "fromString"),
        .method_val = Value.initBuiltinFn(&fromString),
    };
    entries[2] = .{
        .protocol_name = "",
        .method_name = try gpa.dupe(u8, "<init>"),
        .method_val = Value.initBuiltinFn(&uuidCtor),
    };
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.util.UUID",
    .descriptor = &descriptor,
    .init = &initUUID,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.util.UUID",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
