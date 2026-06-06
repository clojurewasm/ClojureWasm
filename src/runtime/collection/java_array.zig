// SPDX-License-Identifier: EPL-2.0
//! Java array (`.array` tag) — a type-erased, mutable, fixed-size `[]Value`
//! (ADR-0105 / D-287). The neutral impl behind clojure.core's
//! `aget`/`aset`/`make-array`/`*-array`/`alength`/`aclone`/`to-array`.
//!
//! Backend: impl-only (keyword: array)
//! Impl deps: none
//! Clojure peer: clojure.core/aget … (via lang/primitive/array.zig)
//!
//! Representation mirrors `type_descriptor.TypedInstance` (ADR-0104): a GC
//! heap object holding a `gc.infra`-owned, traced, in-place-mutable `[]Value`.
//! The element TYPE is erased (F-004 uniform 8-byte Value + F-005 no primitive
//! specialization): `byte-array`/`int-array`/`object-array` all produce this
//! one shape; type hints are advisory (AD-019). Behavioural fidelity to clj is
//! preserved at the *constructor* (per-type init default) and in the byte/
//! short/char *wrap*, not in the storage. Arrays use identity equality.

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

/// A Java array value. `extern struct` so `rt.gc.alloc` accepts it (HeapHeader
/// at offset 0) and the GC walker treats the head as a HeapHeader.
pub const JavaArray = extern struct {
    header: HeapHeader,
    len: u32,
    _pad: [4]u8 = .{ 0, 0, 0, 0 },
    /// `gc.infra`-owned `[]Value`; the finaliser releases it.
    items_ptr: [*]Value,

    comptime {
        std.debug.assert(@alignOf(JavaArray) >= 8);
        std.debug.assert(@offsetOf(JavaArray, "header") == 0);
    }

    pub fn items(self: *const JavaArray) []Value {
        return self.items_ptr[0..self.len];
    }
};

/// Decode a `.array` Value to its `*JavaArray`.
pub fn asArray(v: Value) *const JavaArray {
    return v.decodePtr(*const JavaArray);
}

pub fn isArray(v: Value) bool {
    return v.tag() == .array;
}

/// Allocate a `len`-element array, every slot initialised to `init_val`. The
/// per-constructor clj default (0 / 0.0 / false / \space / nil) is the caller's
/// choice (F-011), passed in as `init_val`.
pub fn make(rt: *Runtime, len: u32, init_val: Value) !Value {
    const buf = try rt.gc.infra.alloc(Value, len);
    errdefer rt.gc.infra.free(buf);
    @memset(buf, init_val);
    const arr = try rt.gc.alloc(JavaArray);
    arr.* = .{
        .header = HeapHeader.init(.array),
        .len = len,
        .items_ptr = buf.ptr,
    };
    return Value.encodeHeapPtr(.array, arr);
}

/// Allocate an array holding a copy of `src` (for `*-array` from a seq,
/// `to-array`, `aclone`). `src` is fully materialised before the alloc, so no
/// half-filled array is ever live across a GC.
pub fn fromSlice(rt: *Runtime, src: []const Value) !Value {
    const buf = try rt.gc.infra.alloc(Value, src.len);
    errdefer rt.gc.infra.free(buf);
    std.mem.copyForwards(Value, buf, src);
    const arr = try rt.gc.alloc(JavaArray);
    arr.* = .{
        .header = HeapHeader.init(.array),
        .len = @intCast(src.len),
        .items_ptr = buf.ptr,
    };
    return Value.encodeHeapPtr(.array, arr);
}

/// `(aget array idx)` — bounds-checked element read.
pub fn aget(arr: Value, idx: i64, fn_name: []const u8, loc: SourceLocation) !Value {
    const a = asArray(arr);
    if (idx < 0 or idx >= a.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = fn_name });
    return a.items()[@intCast(idx)];
}

/// `(aset array idx val)` — in-place write, returns `val` (clj semantics).
/// GC-safe: the slot is already traced (non-moving mark-sweep, no barrier) and
/// `val` is an already-rooted argument; no allocation between, so no collection
/// runs mid-write (same reasoning as `TypedInstance.setField`).
pub fn aset(arr: Value, idx: i64, val: Value, fn_name: []const u8, loc: SourceLocation) !Value {
    const a = asArray(arr);
    if (idx < 0 or idx >= a.len)
        return error_catalog.raise(.index_out_of_range, loc, .{ .fn_name = fn_name });
    a.items_ptr[@intCast(idx)] = val;
    return val;
}

pub fn alength(arr: Value) u32 {
    return asArray(arr).len;
}

/// `(aclone array)` — a fresh array with copied contents (not `identical?`).
pub fn aclone(rt: *Runtime, arr: Value) !Value {
    return fromSlice(rt, asArray(arr).items());
}

/// Trace fn for `.array` — mark every element's heap reference. Mirrors
/// `traceTypedInstance`.
fn traceJavaArray(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const arr: *JavaArray = @ptrCast(@alignCast(header));
    var i: u32 = 0;
    while (i < arr.len) : (i += 1) {
        if (arr.items_ptr[i].heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
    }
}

/// Finaliser for `.array` — release the `gc.infra`-owned element slice.
fn finaliseJavaArray(gc_ptr: *anyopaque, header: *HeapHeader) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const arr: *JavaArray = @ptrCast(@alignCast(header));
    gc.infra.free(arr.items_ptr[0..arr.len]);
}

pub fn registerGcHooks() void {
    tag_ops.registerTrace(.array, &traceJavaArray);
    tag_ops.registerFinaliser(.array, &finaliseJavaArray);
}

// --- tests ---

const testing = std.testing;

test "make + aget/aset + alength" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, 3, Value.nil_val);
    try testing.expectEqual(@as(u32, 3), alength(a));
    try testing.expect((try aget(a, 0, "aget", .{})).isNil());

    _ = try aset(a, 1, Value.initInteger(42), "aset", .{});
    try testing.expectEqual(@as(i48, 42), (try aget(a, 1, "aget", .{})).asInteger());
    try testing.expect((try aget(a, 0, "aget", .{})).isNil());
}

test "aget/aset out of range raises" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, 2, Value.nil_val);
    try testing.expectError(error.IndexError, aget(a, 5, "aget", .{}));
    try testing.expectError(error.IndexError, aget(a, -1, "aget", .{}));
    try testing.expectError(error.IndexError, aset(a, 2, Value.initInteger(1), "aset", .{}));
}

test "aclone copies, not identical" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();

    const a = try make(&rt, 2, Value.initInteger(7));
    const b = try aclone(&rt, a);
    try testing.expect(a != b); // distinct Values (different heap ptrs)
    try testing.expectEqual(@as(i48, 7), (try aget(b, 0, "aget", .{})).asInteger());
    _ = try aset(a, 0, Value.initInteger(99), "aset", .{});
    try testing.expectEqual(@as(i48, 7), (try aget(b, 0, "aget", .{})).asInteger()); // clone unaffected
}
