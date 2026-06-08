// SPDX-License-Identifier: EPL-2.0
//! Marshal cljw `Value` ↔ `zwasm.Value`, driven by an export's runtime
//! signature (`exportFuncSig` ValTypes). The load-bearing piece of the wasm
//! FFI surface (ADR-0099): the untyped dynamic invoke path needs each arg
//! coerced to the param's wasm type and each result decoded from the result's
//! wasm type. i32 / i64 / f32 / f64 are covered; v128 / ref are out of P1
//! scope (Phase-16, when wasm refs become first-class cljw Values per F-004).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/load, wasm/call
const std = @import("std");
const engine = @import("engine.zig");
const ValType = engine.ValType;
const ZValue = engine.Value;
const value_mod = @import("../../value/value.zig");
const Value = value_mod.Value;
const error_catalog = @import("../../error/catalog.zig");
const ClojureWasmError = error_catalog.ClojureWasmError;
const SourceLocation = @import("../../error/info.zig").SourceLocation;

/// Coerce one cljw `Value` to a `zwasm.Value` of the param's wasm type.
pub fn toWasm(arg: Value, vt: ValType, loc: SourceLocation) ClojureWasmError!ZValue {
    switch (vt) {
        .i32 => return ZValue.fromI32(try coerceInt(arg, i32, loc)),
        .i64 => return ZValue.fromI64(try coerceInt(arg, i64, loc)),
        .f32 => {
            if (!arg.isNumber()) return badArg(loc);
            const f: f32 = @floatCast(floatOf(arg));
            return ZValue.fromF32Bits(@bitCast(f));
        },
        .f64 => {
            if (!arg.isNumber()) return badArg(loc);
            return ZValue.fromF64Bits(@bitCast(floatOf(arg)));
        },
        .v128 => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "v128 arguments" }),
        .ref => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "reference-typed arguments" }),
    }
}

/// Decode one `zwasm.Value` result back to a cljw `Value`.
pub fn fromWasm(res: ZValue, loc: SourceLocation) ClojureWasmError!Value {
    switch (res) {
        .i32 => |v| return Value.initInteger(v),
        .i64 => |v| return Value.initInteger(v),
        .f32 => |bits| return Value.initFloat(@as(f32, @bitCast(bits))),
        .f64 => |bits| return Value.initFloat(@bitCast(bits)),
        .v128 => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "v128 results" }),
        .funcref, .externref => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "reference-typed results" }),
    }
}

/// Coerce a cljw number to an integer wasm param of width `T` (i32 / i64),
/// range-checked. A bare `@intCast` here would PANIC in safe builds on any
/// out-of-`T`-range value (e.g. a 40-bit int into an i32 param), and a float arg
/// would silently truncate — both forbidden (SE-10 / F-011: observable behaviour,
/// no silent loss, no host crash on caller data). Rules:
///   - non-number            → error;
///   - float with a fraction → error (1.5 is not an integer arg; 2.0 is allowed);
///   - integer value outside [minInt(T), maxInt(T)] → error;
/// otherwise return the in-range value.
fn coerceInt(arg: Value, comptime T: type, loc: SourceLocation) ClojureWasmError!T {
    if (!arg.isNumber()) return badArg(loc);
    const i: i64 = if (arg.isInt()) arg.asInteger() else blk: {
        const f = arg.asFloat();
        if (@floor(f) != f) return error_catalog.raise(.wasm_arg_not_integer, loc, .{});
        // The float is integral; widen-range check before the i64 cast.
        if (f < @as(f64, @floatFromInt(std.math.minInt(i64))) or f > @as(f64, @floatFromInt(std.math.maxInt(i64))))
            return error_catalog.raise(.wasm_arg_out_of_range, loc, .{});
        break :blk @intFromFloat(f);
    };
    if (i < std.math.minInt(T) or i > std.math.maxInt(T))
        return error_catalog.raise(.wasm_arg_out_of_range, loc, .{});
    return @intCast(i);
}

/// cljw number → f64 (a float passes through; an int widens).
fn floatOf(v: Value) f64 {
    return if (v.isFloat()) v.asFloat() else @floatFromInt(v.asInteger());
}

fn badArg(loc: SourceLocation) ClojureWasmError {
    return error_catalog.raise(.wasm_arg_not_number, loc, .{});
}
