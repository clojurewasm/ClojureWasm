// SPDX-License-Identifier: EPL-2.0
//! Typed views over a loaded module's exported linear memory (ADR-0192). Owns
//! the three things `wasm/mem-read` and `wasm/mem-write!` need and the scalar
//! `wasm/call` path does not: the element-type vocabulary, the element codec,
//! and the bounds arithmetic that turns a caller's (byte offset, element count)
//! into a byte range or a refusal.
//!
//! Encoding is little-endian because that is the wasm memory model, not a host
//! property. Access is unaligned-tolerant (`std.mem.readInt` / `writeInt` over
//! the byte slice, never a pointer cast) because a (ptr,len) ABI hands the host
//! whatever offset the guest's allocator produced.
//!
//! Every fn here refuses by VALUE — `null` or an `ElemError` — and never
//! raises. The catalog Code and its `fn_name` belong to the caller in
//! `surface.zig`, which knows which of the three fns the user actually wrote.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: wasm/mem-size, wasm/mem-read, wasm/mem-write!
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const value_mod = @import("../../value/value.zig");
const Value = value_mod.Value;
const promote = @import("../../numeric/promote.zig");
const big_int = @import("../../numeric/big_int.zig");
const vector_mod = @import("../../collection/vector.zig");
const sub_vector_mod = @import("../../collection/sub_vector.zig");
const java_array = @import("../../collection/java_array.zig");

/// Element type of a linear-memory view. The closed set of wasm-representable
/// numeric widths — closed because it is the wasm memory model's, not an
/// extension point (ADR-0192).
pub const Dtype = enum {
    i8,
    u8,
    i16,
    u16,
    i32,
    u32,
    i64,
    f32,
    f64,

    /// Width of one element in bytes.
    pub fn width(self: Dtype) u32 {
        return switch (self) {
            .i8, .u8 => 1,
            .i16, .u16 => 2,
            .i32, .u32, .f32 => 4,
            .i64, .f64 => 8,
        };
    }
};

/// Map a keyword's name (`:f64` → `"f64"`) to a `Dtype`; `null` when the name
/// is not one of the nine.
pub fn dtypeFromName(name: []const u8) ?Dtype {
    return std.meta.stringToEnum(Dtype, name);
}

/// Why one element could not be encoded. Deliberately NOT catalog Codes: the
/// caller pairs these with the fn name and the element index, which is the
/// information a user needs and which this module does not have.
pub const ElemError = error{
    /// The value is not a number at all.
    NotANumber,
    /// A number, but not an integer, for an integer element type (`1.5` into
    /// an `:i32` buffer). `2.0` is accepted — the rule `marshal.zig::coerceInt`
    /// already applies to `wasm/call` arguments.
    NotAnInteger,
    /// An integer outside the element type's range.
    OutOfRange,
};

/// Byte range within a linear memory, already proven in-bounds.
pub const Range = struct {
    start: usize,
    len: usize,
};

/// Bounds-check a caller's (byte offset, element count) against a memory of
/// `mem_len` bytes. `null` when the range is not addressable.
///
/// All arithmetic is checked i64 and happens BEFORE any access, so a negative
/// offset, a negative count, and an `offset + count*width` that overflows are
/// all ordinary refusals. In ReleaseSafe — the shipped configuration — an
/// unchecked `@intCast` on caller data is a process-killing safety panic, and
/// this surface takes three caller-controlled integers per call.
pub fn byteRange(offset: i64, count: i64, dt: Dtype, mem_len: usize) ?Range {
    if (offset < 0 or count < 0) return null;
    const limit = std.math.cast(i64, mem_len) orelse return null;
    const span = std.math.mul(i64, count, @as(i64, dt.width())) catch return null;
    const end = std.math.add(i64, offset, span) catch return null;
    if (end > limit) return null;
    return .{ .start = @intCast(offset), .len = @intCast(span) };
}

/// Decode one element from `src` (exactly `dt.width()` bytes, little-endian).
///
/// `:i64` routes through `promote.wrapI64`, which keeps a full-width value
/// exact by promoting past the i48 immediate window to a heap Long.
/// `Value.initInteger` would silently demote it to a lossy float — the caller
/// is reading a number a guest computed and has nothing to check it against.
pub fn readElem(rt: *Runtime, dt: Dtype, src: []const u8) !Value {
    return switch (dt) {
        .i8 => Value.initInteger(@as(i8, @bitCast(src[0]))),
        .u8 => Value.initInteger(src[0]),
        .i16 => Value.initInteger(std.mem.readInt(i16, src[0..2], .little)),
        .u16 => Value.initInteger(std.mem.readInt(u16, src[0..2], .little)),
        .i32 => Value.initInteger(std.mem.readInt(i32, src[0..4], .little)),
        .u32 => Value.initInteger(std.mem.readInt(u32, src[0..4], .little)),
        .i64 => try promote.wrapI64(rt, std.mem.readInt(i64, src[0..8], .little)),
        .f32 => Value.initFloat(@as(f32, @bitCast(std.mem.readInt(u32, src[0..4], .little)))),
        .f64 => Value.initFloat(@bitCast(std.mem.readInt(u64, src[0..8], .little))),
    };
}

/// Encode `v` into `dst` (exactly `dt.width()` bytes, little-endian).
pub fn writeElem(v: Value, dt: Dtype, dst: []u8) ElemError!void {
    switch (dt) {
        .i8 => try writeIntElem(v, i8, dst),
        .u8 => try writeIntElem(v, u8, dst),
        .i16 => try writeIntElem(v, i16, dst),
        .u16 => try writeIntElem(v, u16, dst),
        .i32 => try writeIntElem(v, i32, dst),
        .u32 => try writeIntElem(v, u32, dst),
        .i64 => try writeIntElem(v, i64, dst),
        .f32 => {
            const f: f32 = @floatCast(try floatOf(v));
            std.mem.writeInt(u32, dst[0..4], @bitCast(f), .little);
        },
        .f64 => std.mem.writeInt(u64, dst[0..8], @bitCast(try floatOf(v)), .little),
    }
}

fn writeIntElem(v: Value, comptime T: type, dst: []u8) ElemError!void {
    const x = try exactInt(v);
    if (x < std.math.minInt(T) or x > std.math.maxInt(T)) return error.OutOfRange;
    std.mem.writeInt(T, dst[0..@sizeOf(T)], @intCast(x), .little);
}

/// Read `v` as an exact i64. An immediate Long, a heap Long and a BigInt all
/// pass through `promote.exactI64` (so a full-width value written into an
/// `:i64` buffer is not truncated); an integral float is accepted, a
/// fractional one is not.
fn exactInt(v: Value) ElemError!i64 {
    return switch (v.tag()) {
        .integer, .big_int => try promote.exactI64(v),
        .float => blk: {
            const f = v.asFloat();
            if (@floor(f) != f) return error.NotAnInteger;
            // Half-open at the top: maxInt(i64) as an f64 rounds to 2^63, so a
            // `> maxInt` test let 2^63 through to a ReleaseSafe panic.
            if (!(f >= -0x1p63 and f < 0x1p63)) return error.OutOfRange;
            break :blk @intFromFloat(f);
        },
        else => error.NotANumber,
    };
}

/// Read `v` as an f64. An integer widens (a heap Long or BigInt to its nearest
/// double); a float passes through. Matches `marshal.zig::toWasm`'s float arms.
fn floatOf(v: Value) ElemError!f64 {
    return switch (v.tag()) {
        .float => v.asFloat(),
        .integer => @floatFromInt(@as(i64, v.asInteger())),
        .big_int => big_int.asManaged(v).toFloat(f64, .nearest_even)[0],
        else => error.NotANumber,
    };
}

/// A byte offset / element count argument as an exact i64, or `null` when the
/// value is not an integer. Same rule as an element value: an integral float
/// (`2.0`) is accepted, a fractional one is not, and a heap Long / BigInt
/// passes through exactly.
pub fn indexArg(v: Value) ?i64 {
    return exactInt(v) catch null;
}

/// Element count of an indexed vector (`.vector` / `.sub_vector`), or `null`
/// when `v` is neither.
///
/// The write path takes a VECTOR rather than any seqable, the same shape
/// `wasm/run`'s `:args` takes: zone 0 has no seq protocol (`first`/`next` live
/// in `lang/primitive/sequence.zig`, zone 2, which a zone-0 module may not
/// import). A caller holding a lazy seq calls `vec` first.
pub fn indexedCount(v: Value) ?u32 {
    return switch (v.tag()) {
        .vector => vector_mod.count(v),
        .sub_vector => sub_vector_mod.count(v),
        else => null,
    };
}

/// The array kind `wasm/mem-read-array` answers for `dt`: the kind of the
/// same width, or the next wider signed kind for the unsigned `:u16` / `:u32`
/// (`:u8` reads as a byte array, the same bits).
pub fn arrayKindOf(dt: Dtype) java_array.Kind {
    return switch (dt) {
        .i8, .u8 => .byte,
        .i16 => .short,
        .u16, .i32 => .int,
        .u32, .i64 => .long,
        .f32 => .float,
        .f64 => .double,
    };
}

/// True when the elements of primitive array `a` have exactly `dt`'s wasm
/// layout, so a range of linear memory and the array's storage are the same
/// bytes and cross with one memcpy (ADR-0204). Wasm memory is little-endian,
/// so a big-endian host always takes the element-wise path. `:u8` matches a
/// byte array (the same bits, read signed on the Clojure side); `:u16` and
/// `:u32` have no array kind.
pub fn sameLayout(dt: Dtype, a: *const java_array.JavaArray) bool {
    if (@import("builtin").cpu.arch.endian() != .little) return false;
    if (dt == .u16 or dt == .u32) return false;
    return a.kind == arrayKindOf(dt);
}

/// Element `i` of an indexed vector. The caller has already established the
/// tag via `indexedCount` and that `i` is in range.
pub fn indexedNth(v: Value, i: u32) Value {
    return switch (v.tag()) {
        .sub_vector => sub_vector_mod.nth(v, i),
        else => vector_mod.nth(v, i),
    };
}

// --- tests ---

const testing = std.testing;

test "Dtype: names map to the nine widths" {
    try testing.expectEqual(@as(?Dtype, .f64), dtypeFromName("f64"));
    try testing.expectEqual(@as(?Dtype, .u8), dtypeFromName("u8"));
    try testing.expectEqual(@as(?Dtype, null), dtypeFromName("f16"));
    try testing.expectEqual(@as(?Dtype, null), dtypeFromName(""));
    try testing.expectEqual(@as(u32, 8), Dtype.f64.width());
    try testing.expectEqual(@as(u32, 1), Dtype.i8.width());
}

test "byteRange: refuses negative, overflowing and past-the-end ranges" {
    // In bounds, including the exact fit and the empty range.
    try testing.expectEqual(@as(?Range, .{ .start = 0, .len = 16 }), byteRange(0, 2, .f64, 16));
    try testing.expectEqual(@as(?Range, .{ .start = 8, .len = 8 }), byteRange(8, 1, .f64, 16));
    try testing.expectEqual(@as(?Range, .{ .start = 16, .len = 0 }), byteRange(16, 0, .f64, 16));

    // One element past the end.
    try testing.expectEqual(@as(?Range, null), byteRange(9, 1, .f64, 16));
    // Negative offset / count — the ReleaseSafe @intCast panic this exists to avoid.
    try testing.expectEqual(@as(?Range, null), byteRange(-1, 1, .f64, 16));
    try testing.expectEqual(@as(?Range, null), byteRange(0, -1, .f64, 16));
    // count*width overflows i64 before it can be compared to the limit.
    try testing.expectEqual(@as(?Range, null), byteRange(0, std.math.maxInt(i64), .f64, 16));
    // offset + span overflows.
    try testing.expectEqual(@as(?Range, null), byteRange(std.math.maxInt(i64), 1, .i8, 16));
}

test "writeElem: little-endian encoding for every dtype" {
    var buf: [8]u8 = undefined;

    try writeElem(Value.initInteger(-2), .i8, buf[0..1]);
    try testing.expectEqual(@as(u8, 0xfe), buf[0]);

    try writeElem(Value.initInteger(0x1234), .i16, buf[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0x34, 0x12 }, buf[0..2]);

    try writeElem(Value.initInteger(0x01020304), .i32, buf[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, buf[0..4]);

    try writeElem(Value.initFloat(1.0), .f64, buf[0..8]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0xf0, 0x3f }, buf[0..8]);

    try writeElem(Value.initFloat(1.0), .f32, buf[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0x80, 0x3f }, buf[0..4]);
}

test "writeElem: an integer element refuses a fraction and an out-of-range value" {
    var buf: [8]u8 = undefined;

    // 2.0 is an integer written as a float — accepted, same rule as wasm/call args.
    try writeElem(Value.initFloat(2.0), .i32, buf[0..4]);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0 }, buf[0..4]);

    try testing.expectError(error.NotAnInteger, writeElem(Value.initFloat(1.5), .i32, buf[0..4]));
    try testing.expectError(error.OutOfRange, writeElem(Value.initInteger(300), .u8, buf[0..1]));
    try testing.expectError(error.OutOfRange, writeElem(Value.initInteger(-1), .u8, buf[0..1]));
    try testing.expectError(error.NotANumber, writeElem(Value.nil_val, .i32, buf[0..4]));
    try testing.expectError(error.NotANumber, writeElem(Value.nil_val, .f64, buf[0..8]));
}
