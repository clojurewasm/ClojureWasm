// SPDX-License-Identifier: EPL-2.0
//! Java array (`.array` tag): a mutable, fixed-size array with an element
//! kind (ADR-0105 / D-287, typed storage per ADR-0204). The neutral impl
//! behind clojure.core's `aget`/`aset`/`make-array`/`*-array`/`alength`/
//! `aclone`/`to-array`.
//!
//! Backend: impl-only (keyword: array)
//! Impl deps: none
//! Clojure peer: clojure.core/aget … (via lang/primitive/array.zig)
//!
//! A GC heap object holding a `gc.infra`-owned element buffer. An `.object`
//! array stores `Value`s and is traced; every other kind stores raw native
//! elements, contiguous and untraced: `byte` i8, `short` i16, `int` i32,
//! `long` i64, `float` f32, `double` f64, `char` u32 (a code point, cljw chars
//! are not UTF-16 units), `boolean` u8. So a primitive array IS a C array, and
//! a bulk crossing (cljw.ffi, a socket write, `String.`) is one memcpy or a
//! pointer. `get` boxes an element, `store` coerces one (a type mismatch is the
//! catalog's `arg_value_invalid`, clj's "argument type mismatch"). Arrays use
//! identity equality.

const std = @import("std");
const value_mod = @import("../value/value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;
const tag_ops = @import("../gc/tag_ops.zig");
const gc_heap_mod = @import("../gc/gc_heap.zig");
const mark_sweep = @import("../gc/mark_sweep.zig");
const error_catalog = @import("../error/catalog.zig");
const SourceLocation = @import("../error/info.zig").SourceLocation;
const promote = @import("../numeric/promote.zig");
const vector_mod = @import("vector.zig");

/// The element kind of an array. `object` holds any Value; the rest hold
/// native elements of the named C width.
pub const Kind = enum(u8) {
    object,
    boolean,
    byte,
    short,
    char,
    int,
    long,
    float,
    double,

    pub fn fromName(s: []const u8) ?Kind {
        return std.meta.stringToEnum(Kind, s);
    }

    /// Bytes per element.
    pub fn size(k: Kind) usize {
        return switch (k) {
            .object => @sizeOf(Value),
            .boolean, .byte => 1,
            .short => 2,
            .char, .int, .float => 4,
            .long, .double => 8,
        };
    }

    /// The native element type of a primitive kind.
    pub fn Elem(comptime k: Kind) type {
        return switch (k) {
            .object => Value,
            .boolean => u8,
            .byte => i8,
            .short => i16,
            .char => u32,
            .int => i32,
            .long => i64,
            .float => f32,
            .double => f64,
        };
    }

    /// The value a fresh slot holds (clj's per-type default).
    fn default(k: Kind) Value {
        return switch (k) {
            .object => .nil_val,
            .boolean => .false_val,
            .char => Value.initChar(0),
            .float, .double => Value.initFloat(0),
            else => Value.initInteger(0),
        };
    }
};

const ALIGN = std.mem.Alignment.fromByteUnits(8);

/// The element buffer, through `rawAlloc`: `Allocator.alloc` would first fill
/// it with the safe-build `undefined` pattern, a second pass over every byte
/// that `make` overwrites at once.
fn allocData(infra: std.mem.Allocator, n: usize) ![*]align(8) u8 {
    if (n == 0) return @ptrFromInt(ALIGN.toByteUnits());
    const p = infra.rawAlloc(n, ALIGN, @returnAddress()) orelse return error.OutOfMemory;
    return @alignCast(p);
}

fn freeData(infra: std.mem.Allocator, buf: []align(8) u8) void {
    if (buf.len == 0) return;
    infra.rawFree(buf, ALIGN, @returnAddress());
}

/// A Java array value. `extern struct` so `rt.gc.alloc` accepts it (HeapHeader
/// at offset 0) and the GC walker treats the head as a HeapHeader.
pub const JavaArray = extern struct {
    header: HeapHeader,
    len: u32,
    kind: Kind,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// `gc.infra`-owned, 8-aligned, `len * kind.size()` bytes; the finaliser
    /// releases it.
    data: [*]align(8) u8,

    comptime {
        std.debug.assert(@alignOf(JavaArray) >= 8);
        std.debug.assert(@offsetOf(JavaArray, "header") == 0);
    }

    /// The raw element storage, `len * kind.size()` bytes.
    pub fn bytes(self: *const JavaArray) []align(8) u8 {
        return self.data[0 .. self.len * self.kind.size()];
    }

    /// The elements as `T`; the caller has checked `kind`.
    pub fn slice(self: *const JavaArray, comptime k: Kind) []k.Elem() {
        std.debug.assert(self.kind == k);
        const p: [*]k.Elem() = @ptrCast(self.data);
        return p[0..self.len];
    }

    /// The Values of an `.object` array.
    pub fn objects(self: *const JavaArray) []Value {
        return self.slice(.object);
    }
};

/// Decode a `.array` Value to its `*JavaArray`.
pub fn asArray(v: Value) *const JavaArray {
    return v.decodePtr(*const JavaArray);
}

pub fn isArray(v: Value) bool {
    return v.tag() == .array;
}

/// True when `v` is an array of kind `k`.
pub fn isKind(v: Value, k: Kind) bool {
    return isArray(v) and asArray(v).kind == k;
}

/// Allocate a `len`-element array of `kind`, every slot at the kind's default
/// (nil, false, 0, 0.0, the NUL char).
pub fn make(rt: *Runtime, kind: Kind, len: u32) !Value {
    const buf = (try allocData(rt.gc.infra, len * kind.size()))[0 .. len * kind.size()];
    errdefer freeData(rt.gc.infra, buf);
    rt.gc.noteOwnedAlloc(buf.len);
    if (kind == .object) {
        const vals: [*]Value = @ptrCast(buf.ptr);
        @memset(vals[0..len], .nil_val);
    } else @memset(buf, 0);
    const arr = try rt.gc.alloc(JavaArray);
    arr.* = .{
        .header = HeapHeader.init(.array),
        .len = len,
        .kind = kind,
        .data = buf.ptr,
    };
    return Value.encodeHeapPtr(.array, arr);
}

/// Allocate an `.object` array holding a copy of `src` (`to-array`, a host
/// method returning `Object[]`). `src` is fully materialised before the
/// alloc, so no half-filled array is ever live across a GC.
pub fn fromSlice(rt: *Runtime, src: []const Value) !Value {
    const v = try make(rt, .object, @intCast(src.len));
    @memcpy(asArray(v).objects(), src);
    return v;
}

/// Allocate a `.byte` array holding a copy of `src`.
pub fn fromBytes(rt: *Runtime, src: []const u8) !Value {
    const v = try make(rt, .byte, @intCast(src.len));
    @memcpy(asArray(v).bytes(), src);
    return v;
}

/// Element `i` of `a` as a Value. `i < a.len` is the caller's. Allocates only
/// for a `long` outside the immediate-integer range.
pub fn get(rt: *Runtime, a: *const JavaArray, i: usize) !Value {
    return peek(a, i) orelse promote.wrapI64(rt, a.slice(.long)[i]);
}

/// Element `i` of `a` as a Value without allocating, for the rt-free paths
/// (print, key hashing); null for the one element that needs a heap box, a
/// `long` outside the immediate-integer range.
pub fn peek(a: *const JavaArray, i: usize) ?Value {
    return switch (a.kind) {
        .object => a.slice(.object)[i],
        .boolean => Value.initBoolean(a.slice(.boolean)[i] != 0),
        .byte => Value.initInteger(a.slice(.byte)[i]),
        .short => Value.initInteger(a.slice(.short)[i]),
        .char => Value.initChar(@intCast(a.slice(.char)[i])),
        .int => Value.initInteger(a.slice(.int)[i]),
        .long => if (promote.inI48(a.slice(.long)[i])) Value.initInteger(a.slice(.long)[i]) else null,
        .float => Value.initFloat(widenF32(a.slice(.float)[i])),
        .double => Value.initFloat(a.slice(.double)[i]),
    };
}

/// The double a `float` element reads as: the shortest decimal that
/// round-trips the f32, so `(aget (float-array [1.1]) 0)` is 1.1 as clj's
/// boxed Float prints, not the f32's exact 1.100000023841858. cljw has no
/// single-precision Value; the storage is f32 so C sees a `float[]`.
fn widenF32(f: f32) f64 {
    if (!std.math.isFinite(f)) return f;
    var buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{e}", .{f}) catch return f;
    return std.fmt.parseFloat(f64, s) catch f;
}

/// The elements of `a` as Values, in a `gpa` buffer the caller frees: the
/// shape for host code that walks any array as `[]Value` (`Arrays/asList`,
/// `vec`). Boxing a `long` outside the immediate range allocates, and the
/// buffer does not root those boxes, so the caller brackets the boxing and its
/// use with `rt.gc.enterFabrication()` when it allocates in between.
pub fn boxAll(rt: *Runtime, a: *const JavaArray, gpa: std.mem.Allocator) ![]Value {
    const buf = try gpa.alloc(Value, a.len);
    errdefer gpa.free(buf);
    if (a.kind == .object) {
        @memcpy(buf, a.objects());
    } else {
        for (buf, 0..) |*slot, i| slot.* = try get(rt, a, i);
    }
    return buf;
}

/// A vector of `a`'s elements, in order.
pub fn toVector(rt: *Runtime, a: *const JavaArray) !Value {
    if (a.kind == .object) return vector_mod.fromSlice(rt, a.objects());
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const items = try boxAll(rt, a, rt.gpa);
    defer rt.gpa.free(items);
    return vector_mod.fromSlice(rt, items);
}

/// How `store` turns a Value into an element. `strict` is `aset`: the value
/// must already be of the element's category (an integer in range for an
/// integer kind, a number for a floating kind, a char for `char`, a boolean
/// for `boolean`). `convert` is the constructors' Number conversion (clj
/// `RT.byteArray` and friends): an integer wraps to the width, a float
/// truncates into an integer kind, an integer is a char's code point, any
/// value is a boolean by truthiness.
pub const Coerce = enum { strict, convert };

/// The i64 an integer-kind element receives from `v`, or null on a mismatch.
fn integerOf(v: Value, mode: Coerce) ?i64 {
    return switch (v.tag()) {
        .integer => v.asInteger(),
        .big_int => promote.exactI64(v) catch null,
        .char => if (mode == .convert) @as(i64, v.asChar()) else null,
        .float, .ratio, .big_decimal => if (mode == .convert) blk: {
            const f = promote.toF64(v) catch break :blk null;
            if (!std.math.isFinite(f)) break :blk null;
            break :blk std.math.lossyCast(i64, f);
        } else null,
        else => null,
    };
}

fn floatOf(v: Value) ?f64 {
    return switch (v.tag()) {
        .integer, .float, .big_int, .ratio, .big_decimal => promote.toF64(v) catch null,
        else => null,
    };
}

fn mismatch(a: *const JavaArray, v: Value, fn_name: []const u8, loc: SourceLocation) anyerror {
    return error_catalog.raise(.arg_value_invalid, loc, .{
        .fn_name = fn_name,
        .expected = switch (a.kind) {
            .object => unreachable,
            .boolean => "a boolean for a boolean array",
            .char => "a char for a char array",
            .float, .double => "a number for a floating-point array",
            else => "an integer for an integer array",
        },
        .actual = @tagName(v.tag()),
    });
}

/// Store `v` into element `i` of `a` (`i < a.len` is the caller's). GC-safe:
/// an `.object` slot is already traced (non-moving mark-sweep, no barrier) and
/// `v` is a rooted argument; nothing allocates in between.
pub fn store(a: *const JavaArray, i: usize, v: Value, mode: Coerce, fn_name: []const u8, loc: SourceLocation) !void {
    switch (a.kind) {
        .object => a.slice(.object)[i] = v,
        .boolean => a.slice(.boolean)[i] = switch (v.tag()) {
            .boolean => @intFromBool(v == Value.true_val),
            else => if (mode == .convert) @intFromBool(v.isTruthy()) else return mismatch(a, v, fn_name, loc),
        },
        .char => a.slice(.char)[i] = switch (v.tag()) {
            .char => v.asChar(),
            .integer => if (mode == .convert and v.asInteger() >= 0 and v.asInteger() <= std.math.maxInt(u21))
                @intCast(v.asInteger())
            else
                return mismatch(a, v, fn_name, loc),
            else => return mismatch(a, v, fn_name, loc),
        },
        .float => a.slice(.float)[i] = @floatCast(floatOf(v) orelse return mismatch(a, v, fn_name, loc)),
        .double => a.slice(.double)[i] = floatOf(v) orelse return mismatch(a, v, fn_name, loc),
        inline .byte, .short, .int, .long => |k| {
            const x = integerOf(v, mode) orelse return mismatch(a, v, fn_name, loc);
            const T = k.Elem();
            a.slice(k)[i] = std.math.cast(T, x) orelse switch (mode) {
                .convert => @bitCast(@as(std.meta.Int(.unsigned, @bitSizeOf(T)), @truncate(@as(u64, @bitCast(x))))),
                .strict => return error_catalog.raise(.arg_value_invalid, loc, .{
                    .fn_name = fn_name,
                    .expected = "a value in range for a " ++ @tagName(k) ++ " array",
                    .actual = "out-of-range integer",
                }),
            };
        },
    }
}

/// Set every element of `a` to `v` (`Arrays/fill`, the `(int-array n init)`
/// constructor form).
pub fn fill(a: *const JavaArray, v: Value, mode: Coerce, fn_name: []const u8, loc: SourceLocation) !void {
    if (a.len == 0) return;
    try store(a, 0, v, mode, fn_name, loc);
    const sz = a.kind.size();
    const b = a.bytes();
    var i: usize = 1;
    while (i < a.len) : (i += 1) @memcpy(b[i * sz ..][0..sz], b[0..sz]);
}

fn checkIndex(a: *const JavaArray, idx: i64, fn_name: []const u8, loc: SourceLocation) !usize {
    if (idx < 0 or idx >= a.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = fn_name });
    return @intCast(idx);
}

/// `(aget array idx)`: bounds-checked element read.
pub fn aget(rt: *Runtime, arr: Value, idx: i64, fn_name: []const u8, loc: SourceLocation) !Value {
    const a = asArray(arr);
    return get(rt, a, try checkIndex(a, idx, fn_name, loc));
}

/// `(aset array idx val)`: bounds-checked, strictly coerced in-place write;
/// returns `val` (clj semantics).
pub fn aset(arr: Value, idx: i64, val: Value, fn_name: []const u8, loc: SourceLocation) !Value {
    const a = asArray(arr);
    try store(a, try checkIndex(a, idx, fn_name, loc), val, .strict, fn_name, loc);
    return val;
}

pub fn alength(arr: Value) u32 {
    return asArray(arr).len;
}

/// `(aclone array)`: a fresh array of the same kind with copied contents
/// (not `identical?`).
pub fn aclone(rt: *Runtime, arr: Value) !Value {
    const a = asArray(arr);
    const out = try make(rt, a.kind, a.len);
    @memcpy(asArray(out).bytes(), a.bytes());
    return out;
}

/// Copy `n` elements from `src[src_pos..]` to `dst[dst_pos..]`, overlap-safe
/// (`System/arraycopy`). The kinds must match, the range is the caller's.
pub fn copy(src: *const JavaArray, src_pos: usize, dst: *const JavaArray, dst_pos: usize, n: usize) void {
    std.debug.assert(src.kind == dst.kind);
    const sz = src.kind.size();
    @memmove(dst.bytes()[dst_pos * sz ..][0 .. n * sz], src.bytes()[src_pos * sz ..][0 .. n * sz]);
}

/// Trace fn for `.array`: mark every element's heap reference of an
/// `.object` array; a primitive array holds no references.
fn traceJavaArray(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const arr: *JavaArray = @ptrCast(@alignCast(header));
    if (arr.kind != .object) return;
    for (arr.objects()) |v| {
        if (v.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Finaliser for `.array`: release the `gc.infra`-owned element buffer.
fn finaliseJavaArray(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const arr: *JavaArray = @ptrCast(@alignCast(header));
    freeData(gc.infra, arr.bytes());
}

/// D-573: the element storage finaliseJavaArray frees.
fn ownedBytes(header: *HeapHeader) usize {
    const arr: *JavaArray = @ptrCast(@alignCast(header));
    return arr.bytes().len;
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.array, &traceJavaArray);
    tag_ops.registerFinaliser(.array, &finaliseJavaArray);
    tag_ops.registerOwnedBytes(.array, &ownedBytes);
}

// --- tests ---

const testing = std.testing;

test "make + aget/aset + alength" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, .object, 3);
    try testing.expectEqual(@as(u32, 3), alength(a));
    try testing.expect((try aget(&rt, a, 0, "aget", .{})).isNil());

    _ = try aset(a, 1, Value.initInteger(42), "aset", .{});
    try testing.expectEqual(@as(i48, 42), (try aget(&rt, a, 1, "aget", .{})).asInteger());
    try testing.expect((try aget(&rt, a, 0, "aget", .{})).isNil());
}

test "aget/aset out of range raises" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, .long, 2);
    try testing.expectError(error.IndexError, aget(&rt, a, 5, "aget", .{}));
    try testing.expectError(error.IndexError, aget(&rt, a, -1, "aget", .{}));
    try testing.expectError(error.IndexError, aset(a, 2, Value.initInteger(1), "aset", .{}));
}

test "aclone copies, not identical" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, .int, 2);
    try fill(asArray(a), Value.initInteger(7), .strict, "fill", .{});
    const b = try aclone(&rt, a);
    try testing.expect(a != b);
    try testing.expectEqual(Kind.int, asArray(b).kind);
    try testing.expectEqual(@as(i48, 7), (try aget(&rt, b, 0, "aget", .{})).asInteger());
    _ = try aset(a, 0, Value.initInteger(99), "aset", .{});
    try testing.expectEqual(@as(i48, 7), (try aget(&rt, b, 0, "aget", .{})).asInteger());
}

test "a primitive array is contiguous native storage of its width" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const b = try make(&rt, .byte, 3);
    _ = try aset(b, 0, Value.initInteger(-1), "aset", .{});
    try testing.expectError(error.ValueError, aset(b, 1, Value.initInteger(300), "aset", .{}));
    try store(asArray(b), 1, Value.initInteger(300), .convert, "byte-array", .{}); // wraps to 44
    try testing.expectEqualSlices(u8, &.{ 0xFF, 44, 0 }, asArray(b).bytes());

    const f = try make(&rt, .float, 1);
    _ = try aset(f, 0, Value.initFloat(1.1), "aset", .{});
    try testing.expectEqual(@as(f64, 1.1), (try aget(&rt, f, 0, "aget", .{})).asFloat());

    const l = try make(&rt, .long, 1);
    _ = try aset(l, 0, try promote.wrapI64(&rt, std.math.maxInt(i64)), "aset", .{});
    try testing.expectEqual(std.math.maxInt(i64), asArray(l).slice(.long)[0]);
    try testing.expectEqual(std.math.maxInt(i64), try promote.exactI64(try aget(&rt, l, 0, "aget", .{})));

    const d = try make(&rt, .double, 1);
    _ = try aset(d, 0, Value.initInteger(2), "aset", .{});
    try testing.expectEqual(@as(f64, 2), asArray(d).slice(.double)[0]);
}

test "aset rejects a value outside the element category; the ctor mode converts" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const l = try make(&rt, .long, 1);
    try testing.expectError(error.ValueError, aset(l, 0, Value.initFloat(1.5), "aset", .{}));
    try testing.expectError(error.ValueError, aset(l, 0, .nil_val, "aset", .{}));
    try store(asArray(l), 0, Value.initFloat(1.9), .convert, "long-array", .{});
    try testing.expectEqual(@as(i64, 1), asArray(l).slice(.long)[0]);

    const z = try make(&rt, .boolean, 1);
    try testing.expectError(error.ValueError, aset(z, 0, Value.initInteger(1), "aset", .{}));
}
