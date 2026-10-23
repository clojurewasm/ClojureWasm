// SPDX-License-Identifier: EPL-2.0
//! Marshal cljw `Value` ↔ `zwasm.Value`, driven by an export's runtime
//! signature (`exportFuncSig` ValTypes). The load-bearing piece of the wasm
//! FFI surface (ADR-0099): the untyped dynamic invoke path needs each arg
//! coerced to the param's wasm type and each result decoded from the result's
//! wasm type. i32 / i64 / f32 / f64 are covered; v128 / ref are out of P1
//! scope (Phase-16, when wasm refs become first-class cljw Values per F-004).
//!
//! An integer is a cljw immediate only inside the i48 NaN-box window; past it
//! (about +/-2^47) it is a heap Long (tag `.big_int`). Both directions go
//! through the numeric tower, as `cljw.ffi`'s `:long` does: `big_int.toInt`
//! reads an arg exactly (the generic form of `promote.exactI64`), and
//! `promote.wrapI64` builds a result. `Value.initInteger` would demote a result past the window to a
//! lossy Double, and `isNumber` / `isInt` see only the immediate.
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
const Runtime = @import("../../runtime.zig").Runtime;
const promote = @import("../../numeric/promote.zig");
const big_int = @import("../../numeric/big_int.zig");
const error_catalog = @import("../../error/catalog.zig");
const ClojureWasmError = error_catalog.ClojureWasmError;
const SourceLocation = @import("../../error/info.zig").SourceLocation;

/// Coerce one cljw `Value` to a `zwasm.Value` of the param's wasm type.
pub fn toWasm(arg: Value, vt: ValType, loc: SourceLocation) ClojureWasmError!ZValue {
    switch (vt) {
        .i32 => return ZValue.fromI32(try coerceInt(arg, i32, loc)),
        .i64 => return ZValue.fromI64(try coerceInt(arg, i64, loc)),
        .f32 => {
            const f: f32 = @floatCast(try floatOf(arg, loc));
            return ZValue.fromF32Bits(@bitCast(f));
        },
        .f64 => return ZValue.fromF64Bits(@bitCast(try floatOf(arg, loc))),
        .v128 => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "v128 arguments" }),
        .ref => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "reference-typed arguments" }),
    }
}

/// Decode one `zwasm.Value` result back to a cljw `Value`. An i64 is exact
/// over its whole range: `promote.wrapI64` keeps it an immediate inside the
/// i48 window and makes it a heap Long outside it. wasm i64 is signless, so a
/// guest's u64 with the top bit set reads as the negative Long with the same
/// bits (JVM semantics, as `cljw.ffi`'s `:long`). An i64 result may allocate,
/// so a caller lifting several results brackets them in a no-collect region.
pub fn fromWasm(rt: *Runtime, res: ZValue, loc: SourceLocation) anyerror!Value {
    switch (res) {
        .i32 => |v| return Value.initInteger(v),
        .i64 => |v| return promote.wrapI64(rt, v),
        .f32 => |bits| return Value.initFloat(@as(f32, @bitCast(bits))),
        .f64 => |bits| return Value.initFloat(@bitCast(bits)),
        .v128 => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "v128 results" }),
        .funcref, .externref => return error_catalog.raise(.wasm_value_type_unsupported, loc, .{ .what = "reference-typed results" }),
    }
}

/// Coerce a cljw number to an integer wasm param of width `T` (i32 / i64),
/// range-checked. A bare `@intCast` here would PANIC in safe builds on any
/// Shared with the COMPONENT lowering path (`component.zig`), which used a bare
/// `@intCast` and therefore violated this function's own third rule — in
/// ReleaseSafe, the shipped config, an out-of-range cast is a process-killing
/// safety panic, not an error the caller can catch.
///
/// out-of-`T`-range value (e.g. a 40-bit int into an i32 param), and a float arg
/// would silently truncate — both forbidden (SE-10 / F-011: observable behaviour,
/// no silent loss, no host crash on caller data). Rules:
///   - non-number            → error;
///   - float with a fraction → error (1.5 is not an integer arg; 2.0 is allowed);
///   - integer value outside [minInt(T), maxInt(T)] → error;
/// otherwise return the in-range value.
///
/// A heap Long (outside the i48 immediate window) and a BigInt are integers
/// too: `big_int.toInt(T)` reads them exactly, so a WIT `u64` above
/// Long/MAX_VALUE lowers from a BigInt and anything outside `T` is refused.
pub fn coerceInt(arg: Value, comptime T: type, loc: SourceLocation) ClojureWasmError!T {
    switch (arg.tag()) {
        .integer => return std.math.cast(T, @as(i64, arg.asInteger())) orelse outOfRange(loc),
        .big_int => return big_int.asManaged(arg).toInt(T) catch outOfRange(loc),
        .float => {
            const f = arg.asFloat();
            if (@floor(f) != f) return error_catalog.raise(.wasm_arg_not_integer, loc, .{});
            // The float is integral; range-check before the cast. The bounds
            // are the exact powers of two, half-open at the top: maxInt(i64)
            // as an f64 ROUNDS to 2^63, so a `> maxInt` test let 2^63 itself
            // through to `@intFromFloat`, a ReleaseSafe panic on caller data.
            if (!(f >= -0x1p63 and f < 0x1p63)) return outOfRange(loc);
            const i: i64 = @intFromFloat(f);
            return std.math.cast(T, i) orelse outOfRange(loc);
        },
        else => return badArg(loc),
    }
}

/// cljw number to f64: a float passes through, an integer widens (a heap Long
/// or BigInt to its nearest double, as `double` does).
fn floatOf(v: Value, loc: SourceLocation) ClojureWasmError!f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @floatFromInt(@as(i64, v.asInteger())),
        .big_int => big_int.asManaged(v).toFloat(f64, .nearest_even)[0],
        else => badArg(loc),
    };
}

fn outOfRange(loc: SourceLocation) ClojureWasmError {
    return error_catalog.raise(.wasm_arg_out_of_range, loc, .{});
}

fn badArg(loc: SourceLocation) ClojureWasmError {
    return error_catalog.raise(.wasm_arg_not_number, loc, .{});
}
