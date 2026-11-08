// SPDX-License-Identifier: EPL-2.0
//! Primitive arrays across a module's linear memory (ADR-0204): the bulk
//! counterpart of `wasm/mem-read` / `wasm/mem-write!`, which box one Value per
//! element. A primitive array is contiguous little-endian storage of its
//! width, so where its kind matches the dtype a crossing is one memcpy.
//!
//! - `(wasm/mem-read-array h :f64 offset n)` answers a primitive array.
//! - `(wasm/mem-write! h :f64 offset arr)` with a primitive array: `surface.zig`
//!   routes it here.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/mem-read-array, wasm/mem-write!
const std = @import("std");
const engine = @import("engine.zig");
const wasm_memory = @import("memory.zig");
const surface = @import("surface.zig");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const java_array = @import("../../collection/java_array.zig");

fn rangeOf(comptime fn_name: []const u8, mem: engine.Memory, dt: wasm_memory.Dtype, offset: i64, count: i64, loc: SourceLocation) !wasm_memory.Range {
    const len = mem.slice().len;
    const ok = if (count <= std.math.maxInt(u32)) wasm_memory.byteRange(offset, count, dt, len) else null;
    return ok orelse error_catalog.raise(.wasm_memory_range_invalid, loc, .{
        .fn_name = fn_name,
        .offset = offset,
        .count = count,
        .size = len,
    });
}

/// `(wasm/mem-read-array handle :f64 offset n)`: `n` elements at BYTE `offset`
/// as a primitive array: `:f64` a double-array, `:i64` a long-array, `:u16`
/// an int-array and `:u32` a long-array (widened, so every value fits), `:u8`
/// a byte-array of the same bits.
pub fn wasmMemReadArrayFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("wasm/mem-read-array", args, 4, loc);
    const mem = try surface.memoryArg("wasm/mem-read-array", args[0], loc);
    const dt = try surface.dtypeArg("wasm/mem-read-array", args[1], loc);
    const offset = try surface.indexArg("wasm/mem-read-array", args[2], loc);
    const count = try surface.indexArg("wasm/mem-read-array", args[3], loc);
    const range = try rangeOf("wasm/mem-read-array", mem, dt, offset, count, loc);

    const n: u32 = @intCast(count);
    const out = try java_array.make(rt, wasm_memory.arrayKindOf(dt), n);
    const a = java_array.asArray(out);
    const bytes = mem.slice();
    if (wasm_memory.sameLayout(dt, a)) {
        @memcpy(a.bytes(), bytes[range.start..][0..range.len]);
        return out;
    }
    // `:u16` / `:u32` widen, a big-endian host swaps. `out` is the only live
    // allocation and is rooted by the frame below; an i64 box from readElem is
    // stored at once.
    const w: usize = dt.width();
    for (0..n) |i| {
        const at = range.start + i * w;
        const v = try wasm_memory.readElem(rt, dt, bytes[at .. at + w]);
        try java_array.store(a, i, v, .strict, "wasm/mem-read-array", loc);
    }
    return out;
}

/// `wasm/mem-write!` of a primitive array: one memcpy when the array's kind
/// is the dtype's layout, else the element-wise encode with the same per-
/// element refusals as a vector. Returns the element count.
pub fn writeArray(mem: engine.Memory, dt: wasm_memory.Dtype, offset: i64, arr: Value, loc: SourceLocation) anyerror!Value {
    const a = java_array.asArray(arr);
    if (a.kind == .object)
        return error_catalog.raise(.wasm_memory_data_invalid, loc, .{ .fn_name = "wasm/mem-write!" });
    const range = try rangeOf("wasm/mem-write!", mem, dt, offset, a.len, loc);
    const bytes = mem.slice();
    if (wasm_memory.sameLayout(dt, a)) {
        @memcpy(bytes[range.start..][0..range.len], a.bytes());
        return Value.initInteger(a.len);
    }
    const w: usize = dt.width();
    for (0..a.len) |i| {
        const at = range.start + i * w;
        // `peek` boxes without allocating except a long outside i48; take the
        // raw i64 for those so this path never allocates.
        const v = java_array.peek(a, i) orelse {
            const x = a.slice(.long)[i];
            if (dt != .i64) return elemError(i, error.OutOfRange, loc);
            std.mem.writeInt(i64, bytes[at..][0..8], x, .little);
            continue;
        };
        wasm_memory.writeElem(v, dt, bytes[at .. at + w]) catch |e| return elemError(i, e, loc);
    }
    return Value.initInteger(a.len);
}

fn elemError(i: usize, e: wasm_memory.ElemError, loc: SourceLocation) anyerror {
    return error_catalog.raise(.wasm_memory_element_invalid, loc, .{
        .fn_name = "wasm/mem-write!",
        .index = @as(u32, @intCast(i)),
        .detail = switch (e) {
            error.NotANumber => "is not a number",
            error.NotAnInteger => "is not an integer",
            error.OutOfRange => "is outside this element type's range",
        },
    });
}

/// Intern `mem-read-array` into the `wasm` namespace.
pub fn register(env: *Env, ns: anytype) !void {
    _ = try env.intern(ns, "mem-read-array", Value.initBuiltinFn(&wasmMemReadArrayFn), null);
}
