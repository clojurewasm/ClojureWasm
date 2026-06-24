// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.math.BigDecimal`.
//!
//! Backend: impl-only
//! Impl deps: big_decimal
//! Clojure peer: clojure.core/bigdec, clojure.core/+, clojure.core/-,
//!   clojure.core/*, clojure.core// (numeric tower auto-promotion)
//!
//! Thin wrapper over `runtime/numeric/big_decimal.zig` per F-009 — the impl
//! carries the `(unscaled BigInt, i32 scale)` representation declared by F-005.
//! Two surfaces: the static `cljw.java.math.BigDecimal` descriptor (rt.types
//! auto-import) carries the `ROUND_*` rounding-mode constants; the per-Runtime
//! native `.big_decimal` descriptor carries instance methods reached as
//! `(.setScale bd n mode)` — installed by `installNativeMethods` at runtime
//! init (D-097, the math.numeric-tower floor/ceil path D-420). Arithmetic
//! auto-promotion landed earlier via D-014a.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const big_decimal = @import("../../numeric/big_decimal.zig");
const big_int = @import("../../numeric/big_int.zig");
const print_mod = @import("../../print.zig");
const host_instance = @import("../../host_instance.zig");
const rounding_mode = @import("../../rounding_mode.zig");

fn requireBd(v: Value, name: []const u8, loc: SourceLocation) !void {
    if (v.tag() != .big_decimal)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = name, .actual = @tagName(v.tag()) });
}

/// `(.scale bd)` — the scale (number of digits after the decimal point; may be
/// negative). JVM `BigDecimal.scale()`.
fn scaleFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("scale", args, 1, loc);
    try requireBd(args[0], "scale", loc);
    return Value.initInteger(big_decimal.asScale(args[0]));
}

/// `(.signum bd)` — -1 / 0 / 1 by the sign of the value. JVM `BigDecimal.signum()`.
fn signumFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("signum", args, 1, loc);
    try requireBd(args[0], "signum", loc);
    const m = big_decimal.asUnscaled(args[0]).m;
    const s: i64 = if (m.eqlZero()) 0 else if (m.isPositive()) 1 else -1;
    return Value.initInteger(s);
}

/// `(.unscaledValue bd)` — the unscaled significand as a BigInteger (cljw big_int).
/// JVM `BigDecimal.unscaledValue()`.
fn unscaledValueFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("unscaledValue", args, 1, loc);
    try requireBd(args[0], "unscaledValue", loc);
    return big_int.allocFromManaged(rt, big_decimal.asUnscaled(args[0]).m, .bigint);
}

/// `(.negate bd)` — the value with its sign flipped (same scale). JVM
/// `BigDecimal.negate()`.
fn negateFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("negate", args, 1, loc);
    try requireBd(args[0], "negate", loc);
    var m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.copy(big_decimal.asUnscaled(args[0]).m.toConst());
    m.negate();
    return big_decimal.allocFromManagedScale(rt, &m, big_decimal.asScale(args[0]));
}

/// `(BigDecimal/valueOf x)` / `(BigDecimal/valueOf unscaled scale)` — the static
/// factory. JVM `BigDecimal.valueOf`: a `double` is formatted via its canonical
/// string (`Double.toString`) then parsed (so `5.5` → `5.5M`, not the binary
/// approximation); a `long` becomes a scale-0 BigDecimal; the 2-arg form is
/// `unscaled · 10^-scale`. Matches `clojure.core/bigdec` on a double — clj's
/// bigdec of a double IS `BigDecimal/valueOf(double)`.
fn valueOf(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 2) {
        if (args[0].tag() != .integer or args[1].tag() != .integer)
            return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "BigDecimal/valueOf", .actual = @tagName(args[0].tag()) });
        return big_decimal.allocFromI64Scale(rt, args[0].asInteger(), @intCast(args[1].asInteger()));
    }
    try error_catalog.checkArity("BigDecimal/valueOf", args, 1, loc);
    switch (args[0].tag()) {
        .integer => return big_decimal.allocFromI64Scale(rt, args[0].asInteger(), 0),
        .big_int => return big_decimal.allocFromManagedScale(rt, big_int.asManaged(args[0]), 0),
        .float => {
            var fbuf: [400]u8 = undefined;
            var fw: std.Io.Writer = .fixed(&fbuf);
            print_mod.printFloat(&fw, args[0].asFloat()) catch
                return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "BigDecimal/valueOf", .actual = "float" });
            return (try big_decimal.allocFromDecimalString(rt, fw.buffered())) orelse
                error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "BigDecimal/valueOf", .actual = "float" });
        },
        else => |t| return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "BigDecimal/valueOf", .actual = @tagName(t) }),
    }
}

/// `(.abs bd)` — the absolute value (same scale). JVM `BigDecimal.abs()`.
fn absFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("abs", args, 1, loc);
    try requireBd(args[0], "abs", loc);
    const src = big_decimal.asUnscaled(args[0]).m;
    if (src.eqlZero() or src.isPositive()) return args[0]; // already non-negative
    var m = try std.math.big.int.Managed.init(rt.gc.infra);
    defer m.deinit();
    try m.copy(src.toConst());
    m.abs();
    return big_decimal.allocFromManagedScale(rt, &m, big_decimal.asScale(args[0]));
}

/// `(.toBigInteger bd)` — truncate toward zero to a BigInteger (cljw big_int).
/// JVM `BigDecimal.toBigInteger()`.
fn toBigIntegerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toBigInteger", args, 1, loc);
    try requireBd(args[0], "toBigInteger", loc);
    // setScale(0, ROUND_DOWN=1) truncates toward zero (DOWN never needs rounding);
    // the resulting scale-0 BigDecimal's unscaled value IS the integer.
    const truncated = try big_decimal.setScale(rt, args[0], 0, 1);
    return big_int.allocFromManaged(rt, big_decimal.asUnscaled(truncated).m, .bigint);
}

/// `(.stripTrailingZeros bd)` — remove trailing zero digits (the scale-independent
/// normalized projection, ADR-0077). JVM `BigDecimal.stripTrailingZeros()`
/// (e.g. `1.500` → `1.5`, `100` → `1E+2`).
fn stripTrailingZerosFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("stripTrailingZeros", args, 1, loc);
    try requireBd(args[0], "stripTrailingZeros", loc);
    return big_decimal.allocFromManagedScale(rt, big_decimal.asNormUnscaled(args[0]).m, big_decimal.asNormScale(args[0]));
}

/// `(.add a b)` — exact BigDecimal sum (JVM `BigDecimal.add`), the same aligned
/// arithmetic the `+` operator uses. Both args must be BigDecimals.
fn addFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("add", args, 2, loc);
    try requireBd(args[0], "add", loc);
    try requireBd(args[1], "add", loc);
    return big_decimal.allocAdd(rt, args[0], args[1]);
}

/// `(.subtract a b)` — exact BigDecimal difference (JVM `BigDecimal.subtract`).
fn subtractFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("subtract", args, 2, loc);
    try requireBd(args[0], "subtract", loc);
    try requireBd(args[1], "subtract", loc);
    return big_decimal.allocSub(rt, args[0], args[1]);
}

/// `(.multiply a b)` — exact BigDecimal product, scale = sum of scales (JVM
/// `BigDecimal.multiply`).
fn multiplyFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("multiply", args, 2, loc);
    try requireBd(args[0], "multiply", loc);
    try requireBd(args[1], "multiply", loc);
    return big_decimal.allocMul(rt, args[0], args[1]);
}

/// `(.divide a b)` — exact BigDecimal quotient (JVM `BigDecimal.divide(BigDecimal)`,
/// the no-MathContext form): throws on a non-terminating expansion or zero divisor,
/// matching clj `(/ aM bM)` (the shared `allocDiv`).
fn divideFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("divide", args, 2, loc);
    try requireBd(args[0], "divide", loc);
    try requireBd(args[1], "divide", loc);
    return big_decimal.allocDiv(rt, args[0], args[1]) catch |e| switch (e) {
        error.DivideByZero => error_catalog.raise(.divide_by_zero, loc, .{}),
        error.NonTerminatingDecimal => error_catalog.raise(.non_terminating_decimal, loc, .{}),
        else => e,
    };
}

/// `(.movePointLeft bd n)` — `bd ÷ 10ⁿ` (scale +n; JVM `BigDecimal.movePointLeft`).
fn movePointLeftFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("movePointLeft", args, 2, loc);
    try requireBd(args[0], "movePointLeft", loc);
    if (!args[1].isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "movePointLeft", .actual = @tagName(args[1].tag()) });
    return big_decimal.allocMovePoint(rt, args[0], args[1].asInteger());
}

/// `(.movePointRight bd n)` — `bd · 10ⁿ` (scale −n; JVM `BigDecimal.movePointRight`).
fn movePointRightFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("movePointRight", args, 2, loc);
    try requireBd(args[0], "movePointRight", loc);
    if (!args[1].isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "movePointRight", .actual = @tagName(args[1].tag()) });
    return big_decimal.allocMovePoint(rt, args[0], -args[1].asInteger());
}

/// `(.precision bd)` — the number of significant digits in the unscaled value
/// (a zero value has precision 1). JVM `BigDecimal.precision()`.
fn precisionFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("precision", args, 1, loc);
    try requireBd(args[0], "precision", loc);
    const m = big_decimal.asUnscaled(args[0]).m;
    const s = try m.toString(rt.gc.infra, 10, .lower);
    defer rt.gc.infra.free(s);
    var digits: []const u8 = s;
    if (digits.len > 0 and digits[0] == '-') digits = digits[1..];
    const prec: i64 = if (digits.len == 0) 1 else @intCast(digits.len);
    return Value.initInteger(prec);
}

/// `(.setScale bd newScale)` / `(.setScale bd newScale roundingMode)` — JVM
/// `BigDecimal.setScale(int)` / `setScale(int, int)`. `newScale` is the desired
/// scale; `roundingMode` is a `ROUND_*` int constant. The 1-arg-method (2 total)
/// form is `ROUND_UNNECESSARY` (rescale exactly, throw if rounding is needed).
fn setScale(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArityRange("setScale", args, 2, 3, loc);
    if (args[0].tag() != .big_decimal)
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "setScale", .actual = @tagName(args[0].tag()) });
    // ROUND_UNNECESSARY (7) for the no-mode form (JVM setScale(int)). The mode
    // arg is either a deprecated `ROUND_*` int OR a `RoundingMode` enum constant
    // (a host_instance carrying its ordinal in state[0]) — both decode to 0-7.
    const mode: i64 = if (args.len == 3) blk: {
        if (args[2].tag() == .host_instance) {
            const hi = host_instance.asHostInstance(args[2]);
            if (hi.descriptor.fqcn) |fqcn| {
                if (std.mem.eql(u8, fqcn, "java.math.RoundingMode"))
                    break :blk @intCast(hi.state[0]);
            }
        }
        if (!args[2].isInt())
            return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "setScale", .actual = "non-integer scale/mode" });
        break :blk args[2].asInteger();
    } else 7;
    if (!args[1].isInt())
        return error_catalog.raise(.type_arg_not_number, loc, .{ .fn_name = "setScale", .actual = "non-integer scale/mode" });
    return big_decimal.setScale(rt, args[0], @intCast(args[1].asInteger()), mode) catch |e| switch (e) {
        error.RoundingNecessary => error_catalog.raise(.rounding_necessary, loc, .{}),
        error.InvalidRoundingMode => error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "setScale", .expected = "a ROUND_* mode (0-7)", .actual = "an unknown rounding mode" }),
        else => e,
    };
}

/// Populate the per-Runtime native `.big_decimal` descriptor's `method_table`
/// (D-097). Driven from `lang/primitive.zig` at runtime init (Layer 2 — Layer 0
/// `runtime/` may not import this surface). Idempotent: a non-empty table
/// short-circuits. Allocations land on `rt.gc.infra` (freed by the
/// native-descriptor pass in `Runtime.deinit`).
pub fn installNativeMethods(rt: *Runtime) !void {
    const td = try rt.nativeDescriptor(.big_decimal);
    if (td.method_table.len != 0) return; // idempotent re-run
    const gpa = rt.gc.infra;
    const specs = .{
        .{ "setScale", &setScale },
        .{ "scale", &scaleFn },
        .{ "signum", &signumFn },
        .{ "unscaledValue", &unscaledValueFn },
        .{ "precision", &precisionFn },
        .{ "negate", &negateFn },
        .{ "abs", &absFn },
        .{ "toBigInteger", &toBigIntegerFn },
        .{ "stripTrailingZeros", &stripTrailingZerosFn },
        .{ "add", &addFn },
        .{ "subtract", &subtractFn },
        .{ "multiply", &multiplyFn },
        .{ "divide", &divideFn },
        .{ "movePointLeft", &movePointLeftFn },
        .{ "movePointRight", &movePointRightFn },
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

/// Populate the static `cljw.java.math.BigDecimal` descriptor's `method_table`
/// with the class static methods (`BigDecimal/valueOf`). Mirrors `Long.initLong`;
/// runs once at module install (the static-field constants are comptime, but a
/// `Value.initBuiltinFn` method entry cannot be built at module-scope comptime).
fn initStatic(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent re-run
    const specs = .{
        .{ "valueOf", &valueOf },
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
    .cljw_ns = "cljw.java.math.BigDecimal",
    .descriptor = &descriptor,
    .init = &initStatic,
};

/// The deprecated-but-still-public `BigDecimal.ROUND_*` int constants
/// (java.math.BigDecimal). Real Clojure libs (clojure.math.numeric-tower's
/// floor/ceil) read them for `(.setScale n 0 BigDecimal/ROUND_FLOOR)`. Generated
/// from the canonical `rounding_mode` name↔ordinal table so the `ROUND_<name>`
/// suffix + ordinal stay a single source of truth shared with the modern
/// `RoundingMode/<name>` enum constants (ADR-0160).
const big_decimal_static_fields = build: {
    var arr: [rounding_mode.COUNT]type_descriptor.TypeDescriptor.StaticField = undefined;
    for (&arr, 0..) |*sf, i| {
        sf.* = .{ .name = "ROUND_" ++ rounding_mode.name(@intCast(i)), .value = .{ .int = @intCast(i) } };
    }
    break :build arr;
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "cljw.java.math.BigDecimal",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
    .static_fields = &big_decimal_static_fields,
};
