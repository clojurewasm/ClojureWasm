// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.math.MathContext` — a host instance pairing a
//! significant-figure `precision` (state[0]) with a `RoundingMode` ordinal
//! (state[1]). Constructible as `(MathContext. precision)` (HALF_UP default) or
//! `(MathContext. precision RoundingMode/X)`, and consumed by BigDecimal
//! `.round(mc)` / `.divide(divisor, mc)` (D-511). The `with-precision` macro
//! reaches the same precision-rounding via the internal `*math-context*` int var
//! (D-467) — this surface is the explicit object form.
//!
//! Backend: impl-only
//! Impl deps: host_enum, big_decimal, math_context
//! Clojure peer: none.
//!
//! `<init>` + the instance methods are registered on the rt.types descriptor in
//! `initMathContext`; dispatch reads the descriptor off the instance (ADR-0106).
//! The DECIMAL32/64/128/UNLIMITED static constants resolve to per-Runtime cached
//! singletons via the neutral `math_context.zig` (D-511).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const string_collection = @import("../../collection/string.zig");
const host_enum = @import("../../host_enum.zig");

/// The live rt.types descriptor (set in `initMathContext`), embedded into every
/// instance so the `<init>` path and method dispatch share it.
var mc_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// A rounding-mode constructor argument: a `RoundingMode` enum constant
/// (host_instance, ordinal in state[0]) or a `ROUND_*` int — both → 0-7.
fn decodeMode(v: Value, loc: SourceLocation) !i64 {
    if (v.tag() == .host_instance) {
        const hi = host_instance.asHostInstance(v);
        if (hi.descriptor.fqcn) |fqcn| {
            if (std.mem.eql(u8, fqcn, "java.math.RoundingMode")) return @intCast(hi.state[0]);
        }
    }
    if (!v.isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "MathContext", .actual = "non-integer rounding mode" });
    return v.asInteger();
}

/// `(MathContext. precision)` (HALF_UP) / `(MathContext. precision mode)`.
fn initMathContextInstance(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("MathContext", args, 1, 2, loc);
    if (!args[0].isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "MathContext", .actual = "non-integer precision" });
    const precision = args[0].asInteger();
    if (precision < 0)
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "MathContext", .expected = "a non-negative precision", .actual = "a negative precision" });
    const mode: i64 = if (args.len == 2) try decodeMode(args[1], loc) else 4; // HALF_UP
    const td = mc_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intCast(precision), @intCast(mode), 0, 0 });
}

/// `(.getPrecision mc)` — the significant-figure count.
fn getPrecisionFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    _ = rt;
    try error_catalog.checkArity("getPrecision", args, 1, loc);
    return Value.initInteger(@intCast(host_instance.asHostInstance(args[0]).state[0]));
}

/// `(.getRoundingMode mc)` — the RoundingMode enum constant.
fn getRoundingModeFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getRoundingMode", args, 1, loc);
    return host_enum.singleton(rt, .rounding_mode, @intCast(host_instance.asHostInstance(args[0]).state[1]));
}

/// `(str mc)` / `(.toString mc)` — "precision=N roundingMode=NAME" (JVM form).
fn toStringFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    const hi = host_instance.asHostInstance(args[0]);
    var buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "precision={d} roundingMode={s}", .{ hi.state[0], host_enum.name(.rounding_mode, @intCast(hi.state[1])) }) catch unreachable;
    return string_collection.alloc(rt, s);
}

/// The 4 IEEE-754 standard contexts; each resolves to its cached singleton
/// (precision + RoundingMode pair) via `math_context.zig` (D-511).
const static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "DECIMAL32", .value = .{ .math_context = 0 } },
    .{ .name = "DECIMAL64", .value = .{ .math_context = 1 } },
    .{ .name = "DECIMAL128", .value = .{ .math_context = 2 } },
    .{ .name = "UNLIMITED", .value = .{ .math_context = 3 } },
};

const METHODS = [_]struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value }{
    .{ .name = "<init>", .f = &initMathContextInstance },
    .{ .name = "getPrecision", .f = &getPrecisionFn },
    .{ .name = "getRoundingMode", .f = &getRoundingModeFn },
    .{ .name = "toString", .f = &toStringFn },
};

fn initMathContext(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    mc_descriptor = td;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    inline for (METHODS, 0..) |m, i| {
        entries[i] = .{ .protocol_name = "", .method_name = try gpa.dupe(u8, m.name), .method_val = Value.initBuiltinFn(m.f) };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.math.MathContext",
    .descriptor = &descriptor,
    .init = &initMathContext,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.math.MathContext",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &static_fields,
    .parent = null,
    .meta = .nil_val,
};
