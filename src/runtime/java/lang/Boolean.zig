// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Boolean` static methods + fields.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: none
//!
//! Completes the java.lang scalar-class static cluster (Integer / Long /
//! Double / Character / Boolean). `parseBoolean` is case-INSENSITIVE
//! "true" → true, anything else → false (never nil) — distinct from
//! `clojure.core/parse-boolean` (strict, nil on miss), so it is NOT a
//! delegation. `TRUE` / `FALSE` are bool static fields (ADR-0061 +
//! the StaticFieldValue.bool amendment). cljw has no boxed Boolean; the
//! canonical `true`/`false` Values are returned directly.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const string_mod = @import("../../collection/string.zig");

/// JVM `Boolean.parseBoolean`: case-insensitive "true" → true, anything
/// else (incl. "yes", "1", "") → false.
fn parseBool(s: []const u8) bool {
    return std.ascii.eqlIgnoreCase(s, "true");
}

/// Implements `(Boolean/parseBoolean s)`.
/// JVM reference: java.lang.Boolean#parseBoolean.
/// cw v1 tier: A (§A26 clj differential sweep).
fn parseBoolean(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Boolean/parseBoolean", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Boolean/parseBoolean", .actual = @tagName(args[0].tag()) });
    return Value.initBoolean(parseBool(string_mod.asString(args[0])));
}

/// Implements `(Boolean/valueOf x)`. A String parses (like parseBoolean);
/// a boolean is returned as-is. JVM reference: java.lang.Boolean#valueOf.
/// cw v1 tier: A (§A26 clj differential sweep).
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Boolean/valueOf", args, 1, loc);
    return switch (args[0].tag()) {
        .string => Value.initBoolean(parseBool(string_mod.asString(args[0]))),
        .boolean => args[0],
        else => error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Boolean/valueOf", .expected = "boolean or string", .actual = @tagName(args[0].tag()) }),
    };
}

/// Implements `(Boolean/toString b)` — the string "true" / "false".
/// JVM reference: java.lang.Boolean#toString(boolean).
/// cw v1 tier: A (§A26 clj differential sweep).
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Boolean/toString", args, 1, loc);
    if (args[0].tag() != .boolean)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "Boolean/toString", .expected = "boolean", .actual = @tagName(args[0].tag()) });
    return string_mod.alloc(rt, if (args[0] == Value.true_val) "true" else "false");
}

fn argBool(v: Value, fn_name: []const u8, loc: SourceLocation) anyerror!bool {
    if (v.tag() != .boolean)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = fn_name, .expected = "boolean", .actual = @tagName(v.tag()) });
    return v == Value.true_val;
}

/// `Boolean/logicalAnd` / `logicalOr` / `logicalXor`: two-bool statics.
/// JVM reference: java.lang.Boolean#logical{And,Or,Xor}.
const LogicalKind = enum { land, lor, lxor };
fn Logical(comptime op: LogicalKind, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Boolean/" ++ name, args, 2, loc);
            const a = try argBool(args[0], "Boolean/" ++ name, loc);
            const b = try argBool(args[1], "Boolean/" ++ name, loc);
            return Value.initBoolean(switch (op) {
                .land => a and b,
                .lor => a or b,
                .lxor => a != b,
            });
        }
    };
}

/// `(Boolean/compare a b)` — `(a == b) ? 0 : (a ? 1 : -1)`, so `false` sorts
/// before `true`. JVM reference: java.lang.Boolean#compare.
fn compare(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Boolean/compare", args, 2, loc);
    const a = try argBool(args[0], "Boolean/compare", loc);
    const b = try argBool(args[1], "Boolean/compare", loc);
    return Value.initInteger(if (a == b) 0 else if (a) 1 else -1);
}

/// `(Boolean/hashCode b)` — Java's specified constants: `true` → 1231,
/// `false` → 1237. JVM reference: java.lang.Boolean#hashCode.
fn hashCode(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Boolean/hashCode", args, 1, loc);
    const b = try argBool(args[0], "Boolean/hashCode", loc);
    return Value.initInteger(if (b) 1231 else 1237);
}

fn initBoolean(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseBoolean", &parseBoolean },
        .{ "valueOf", &valueOf },
        .{ "toString", &toString },
        .{ "logicalAnd", &Logical(.land, "logicalAnd").call },
        .{ "logicalOr", &Logical(.lor, "logicalOr").call },
        .{ "logicalXor", &Logical(.lxor, "logicalXor").call },
        .{ "compare", &compare },
        .{ "hashCode", &hashCode },
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

// Static fields (ADR-0061 + .bool amendment) — comptime-const.
const boolean_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "TRUE", .value = .{ .bool = true } },
    .{ .name = "FALSE", .value = .{ .bool = false } },
};

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.lang.Boolean",
    .descriptor = &descriptor,
    .init = &initBoolean,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.lang.Boolean",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &boolean_static_fields,
    .parent = null,
    .meta = .nil_val,
};
