// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.lang.Double` static methods.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: clojure.core/parse-double
//!
//! Thin wrapper over the shared `runtime/numeric/parse.zig` leaf
//! (`parseFloat`, shared with `clojure.core/parse-double`, F-011 DRY) +
//! `std.math` predicates. `parseDouble` trims whitespace and rejects
//! `_` to match Java; an `Infinity` / `-Infinity` / `NaN` string parses
//! to the corresponding f64. Malformed input raises a `number_error`-Kind
//! Code → NumberFormatException (ADR-0060). isNaN / isInfinite widen an
//! integer arg to f64 (Java's `double` parameter).

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const parse = @import("../../numeric/parse.zig");
const string_mod = @import("../../collection/string.zig");
const print_mod = @import("../../print.zig");

/// Implements `(Double/parseDouble s)`. Spec: parse an f64; malformed ⇒
/// NumberFormatException. Surrounding whitespace is trimmed (Java).
/// JVM reference: java.lang.Double#parseDouble.
/// cw v1 tier: A (§A26 clj differential sweep).
fn parseDouble(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Double/parseDouble", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "Double/parseDouble", .actual = @tagName(args[0].tag()) });
    const s = string_mod.asString(args[0]);
    const f = parse.parseFloat(s) catch
        return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Double/parseDouble", .text = s });
    return Value.initFloat(f);
}

/// `Double/isNaN` and `isInfinite` share one shape: widen the number arg
/// to f64 (Java's `double` parameter) and apply the std.math predicate.
fn Predicate(comptime name: []const u8, comptime f: fn (f64) bool) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Double/" ++ name, args, 1, loc);
            const x = try error_catalog.expectNumber(args[0], "Double/" ++ name, loc);
            return if (f(x)) .true_val else .false_val;
        }
    };
}

fn isNanF(x: f64) bool {
    return std.math.isNan(x);
}
fn isInfF(x: f64) bool {
    return std.math.isInf(x);
}

/// `(Double/toString d)` — the f64's print form (same as `(str d)`).
/// JVM reference: java.lang.Double#toString.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("Double/toString", args, 1, loc);
    const x = try error_catalog.expectNumber(args[0], "Double/toString", loc);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try print_mod.printFloat(&w, x);
    return string_mod.alloc(rt, w.buffered());
}

/// `(Double/valueOf x)` — a String parses (like parseDouble), a number
/// widens to f64. JVM reference: java.lang.Double#valueOf.
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("Double/valueOf", args, 1, loc);
    if (args[0].tag() == .string) {
        const s = string_mod.asString(args[0]);
        const f = parse.parseFloat(s) catch
            return error_catalog.raise(.number_format_invalid, loc, .{ .fn_name = "Double/valueOf", .text = s });
        return Value.initFloat(f);
    }
    return Value.initFloat(try error_catalog.expectNumber(args[0], "Double/valueOf", loc));
}

/// JVM `Double.doubleToLongBits` total order: all NaNs collapse to one
/// canonical bit pattern; -0.0 sorts below +0.0. Used by `compare`.
fn doubleToLongBits(x: f64) i64 {
    if (std.math.isNan(x)) return @bitCast(@as(u64, 0x7ff8000000000000));
    return @bitCast(x);
}

/// JVM `Double.compare`: the `doubleToLongBits` total order, so -0.0 < +0.0
/// and NaN is greatest. The raw f64 `<`/`>` (which treats ±0.0 as equal and
/// orders NaN nowhere) only resolves the strict-inequality cases; the
/// bit-order tie-break covers ±0.0 and any-NaN.
fn fcompare(a: f64, b: f64) i64 {
    if (a < b) return -1;
    if (a > b) return 1;
    const ab = doubleToLongBits(a);
    const bb = doubleToLongBits(b);
    return if (ab == bb) 0 else if (ab < bb) -1 else 1;
}

/// `Double/compare` / `max` / `min` / `sum`: two-number f64 statics.
/// JVM reference: java.lang.Double#compare/max/min/sum.
const FBinop = enum { compare, max, min, sum };
fn FBinOp2(comptime op: FBinop, comptime name: []const u8) type {
    return struct {
        fn call(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
            _ = rt;
            _ = env;
            try error_catalog.checkArity("Double/" ++ name, args, 2, loc);
            const a = try error_catalog.expectNumber(args[0], "Double/" ++ name, loc);
            const b = try error_catalog.expectNumber(args[1], "Double/" ++ name, loc);
            return switch (op) {
                .compare => Value.initInteger(fcompare(a, b)),
                .max => Value.initFloat(@max(a, b)),
                .min => Value.initFloat(@min(a, b)),
                .sum => Value.initFloat(a + b),
            };
        }
    };
}

fn initDouble(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "parseDouble", &parseDouble },
        .{ "isNaN", &Predicate("isNaN", isNanF).call },
        .{ "isInfinite", &Predicate("isInfinite", isInfF).call },
        .{ "toString", &toString },
        .{ "valueOf", &valueOf },
        .{ "compare", &FBinOp2(.compare, "compare").call },
        .{ "max", &FBinOp2(.max, "max").call },
        .{ "min", &FBinOp2(.min, "min").call },
        .{ "sum", &FBinOp2(.sum, "sum").call },
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
    .cljw_ns = "cljw.java.lang.Double",
    .descriptor = &descriptor,
    .init = &initDouble,
};

// Static fields (ADR-0061) — comptime-const. Java Double.MAX_VALUE /
// MIN_VALUE = the largest finite double / smallest positive denormal.
// Values are exact; their scientific-notation print form is D-166.
const double_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "MAX_VALUE", .value = .{ .float = std.math.floatMax(f64) } },
    .{ .name = "MIN_VALUE", .value = .{ .float = std.math.floatTrueMin(f64) } },
    // Unbiased binary exponent bounds of a normal double (int constants).
    .{ .name = "MAX_EXPONENT", .value = .{ .int = 1023 } },
    .{ .name = "MIN_EXPONENT", .value = .{ .int = -1022 } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.lang.Double",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &double_static_fields,
    .parent = null,
    .meta = .nil_val,
};
