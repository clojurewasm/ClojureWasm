// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Array builtins — make-array, object-array, aget, aset, alength, aclone, to-array, into-array
//!
//! Mutable typed arrays, equivalent to JVM's Object[] / int[] etc.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const collections = @import("../runtime/collections.zig");
const ZigArray = collections.ZigArray;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../runtime/error.zig");

// ============================================================
// Helper: create a ZigArray with nil-initialized items
// ============================================================

fn createArray(allocator: Allocator, size: usize, elem_type: ZigArray.ElementType) !Value {
    const items = try allocator.alloc(Value, size);
    @memset(items, Value.nil_val);
    const arr = try allocator.create(ZigArray);
    arr.* = .{ .items = items, .element_type = elem_type };
    return Value.initArray(arr);
}

// ============================================================
// Builtin functions
// ============================================================

/// (make-array type size) or (make-array type dim & more-dims)
/// Type argument is ignored in CW (no Java class hierarchy).
/// Multi-dim: (make-array Object 2 3) creates 2-element array of 3-element arrays.
fn makeArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to make-array", .{args.len});
    // First arg is type (symbol), ignored. Remaining are dimensions.
    const dims = args[1..];
    return makeArrayMultiDim(allocator, dims);
}

fn makeArrayMultiDim(allocator: Allocator, dims: []const Value) anyerror!Value {
    if (dims.len == 0) return Value.nil_val;
    const size_val = dims[0];
    if (size_val.tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "make-array size must be integer, got {s}", .{@tagName(size_val.tag())});
    const size_i = size_val.asInteger();
    if (size_i < 0) return err.setErrorFmt(.eval, .value_error, .{}, "make-array size must be non-negative, got {d}", .{size_i});
    const size: usize = @intCast(size_i);

    const arr_val = try createArray(allocator, size, .object);

    // Multi-dim: fill each element with sub-array
    if (dims.len > 1) {
        const sub_dims = dims[1..];
        const arr = arr_val.asArray();
        for (arr.items) |*item| {
            item.* = try makeArrayMultiDim(allocator, sub_dims);
        }
    }
    return arr_val;
}

/// (object-array size-or-coll)
/// If integer: creates Object array of that size, filled with nil.
/// If collection: creates Object array from collection elements.
fn objectArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to object-array", .{args.len});
    const arg = args[0];
    if (arg.tag() == .integer) {
        const size_i = arg.asInteger();
        if (size_i < 0) return err.setErrorFmt(.eval, .value_error, .{}, "object-array size must be non-negative, got {d}", .{size_i});
        return createArray(allocator, @intCast(size_i), .object);
    }
    // Collection: convert to array
    return collToArray(allocator, arg);
}

/// Convert any seqable collection to an Object array.
fn collToArray(allocator: Allocator, coll: Value) anyerror!Value {
    switch (coll.tag()) {
        .vector => {
            const vec = coll.asVector();
            const items = try allocator.alloc(Value, vec.items.len);
            @memcpy(items, vec.items);
            const arr = try allocator.create(ZigArray);
            arr.* = .{ .items = items, .element_type = .object };
            return Value.initArray(arr);
        },
        .list => {
            const lst = coll.asList();
            const items = try allocator.alloc(Value, lst.items.len);
            @memcpy(items, lst.items);
            const arr = try allocator.create(ZigArray);
            arr.* = .{ .items = items, .element_type = .object };
            return Value.initArray(arr);
        },
        .array => {
            const src = coll.asArray();
            const items = try allocator.alloc(Value, src.items.len);
            @memcpy(items, src.items);
            const arr = try allocator.create(ZigArray);
            arr.* = .{ .items = items, .element_type = src.element_type };
            return Value.initArray(arr);
        },
        .nil => {
            return createArray(allocator, 0, .object);
        },
        else => {
            // Fallback: iterate via first/rest for lazy seqs, cons, etc.
            return seqToArray(allocator, coll);
        },
    }
}

/// Realize a seqable value into an array by walking first/rest.
fn seqToArray(allocator: Allocator, coll: Value) anyerror!Value {
    var items = std.ArrayList(Value).empty;
    var current = coll;
    while (true) {
        switch (current.tag()) {
            .nil => break,
            .cons => {
                const c = current.asCons();
                try items.append(allocator, c.first);
                current = c.rest;
            },
            .lazy_seq => {
                const collections_builtin = @import("collections.zig");
                current = try collections_builtin.realizeValue(allocator, current);
                // After realization, loop to handle the resulting type
            },
            .chunked_cons => {
                const cc = current.asChunkedCons();
                var i: usize = 0;
                while (i < cc.chunk.count()) : (i += 1) {
                    const elem = cc.chunk.nth(i) orelse Value.nil_val;
                    try items.append(allocator, elem);
                }
                current = cc.more;
            },
            .map => {
                const m = current.asMap();
                var i: usize = 0;
                while (i + 1 < m.entries.len) : (i += 2) {
                    // Each map entry as a vector [k v]
                    const entry_items = try allocator.alloc(Value, 2);
                    entry_items[0] = m.entries[i];
                    entry_items[1] = m.entries[i + 1];
                    const vec = try allocator.create(collections.PersistentVector);
                    vec.* = .{ .items = entry_items };
                    try items.append(allocator, Value.initVector(vec));
                }
                break;
            },
            .hash_map => {
                const hm = current.asHashMap();
                const entries = try hm.toEntries(allocator);
                var i: usize = 0;
                while (i + 1 < entries.len) : (i += 2) {
                    const entry_items = try allocator.alloc(Value, 2);
                    entry_items[0] = entries[i];
                    entry_items[1] = entries[i + 1];
                    const vec = try allocator.create(collections.PersistentVector);
                    vec.* = .{ .items = entry_items };
                    try items.append(allocator, Value.initVector(vec));
                }
                break;
            },
            .set => {
                const s = current.asSet();
                for (s.items) |item| {
                    try items.append(allocator, item);
                }
                break;
            },
            .vector => {
                const vec = current.asVector();
                for (vec.items) |item| {
                    try items.append(allocator, item);
                }
                break;
            },
            .list => {
                const lst = current.asList();
                for (lst.items) |item| {
                    try items.append(allocator, item);
                }
                break;
            },
            .string => {
                // String → array of chars
                const str = current.asString();
                var iter = std.unicode.Utf8View.initUnchecked(str);
                var it = iter.iterator();
                while (it.nextCodepoint()) |cp| {
                    try items.append(allocator, Value.initChar(cp));
                }
                break;
            },
            else => return err.setErrorFmt(.eval, .type_error, .{}, "Don't know how to create array from {s}", .{@tagName(current.tag())}),
        }
    }
    const result_items = try allocator.alloc(Value, items.items.len);
    @memcpy(result_items, items.items);
    const arr = try allocator.create(ZigArray);
    arr.* = .{ .items = result_items, .element_type = .object };
    return Value.initArray(arr);
}

/// (aget array idx) or (aget array idx & idxs) for multi-dim
fn agetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to aget", .{args.len});
    var current = args[0];
    for (args[1..]) |idx_val| {
        if (current.tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, "aget expects array, got {s}", .{@tagName(current.tag())});
        if (idx_val.tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "aget index must be integer, got {s}", .{@tagName(idx_val.tag())});
        const idx_i = idx_val.asInteger();
        const arr = current.asArray();
        if (idx_i < 0 or idx_i >= @as(i64, @intCast(arr.items.len))) {
            return err.setErrorFmt(.eval, .index_error, .{}, "Array index out of bounds: {d} (length {d})", .{ idx_i, arr.items.len });
        }
        current = arr.items[@intCast(idx_i)];
    }
    _ = allocator;
    return current;
}

/// (aset array idx val) or (aset array idx idx2 ... val) for multi-dim
fn asetFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 3) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to aset", .{args.len});
    _ = allocator;
    // Navigate to the innermost array for multi-dim
    var current = args[0];
    const indices = args[1 .. args.len - 1];
    const val = args[args.len - 1];

    for (indices[0 .. indices.len - 1]) |idx_val| {
        if (current.tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, "aset expects array, got {s}", .{@tagName(current.tag())});
        if (idx_val.tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "aset index must be integer, got {s}", .{@tagName(idx_val.tag())});
        const idx_i = idx_val.asInteger();
        const arr = current.asArray();
        if (idx_i < 0 or idx_i >= @as(i64, @intCast(arr.items.len))) {
            return err.setErrorFmt(.eval, .index_error, .{}, "Array index out of bounds: {d} (length {d})", .{ idx_i, arr.items.len });
        }
        current = arr.items[@intCast(idx_i)];
    }

    // Set value at final index
    if (current.tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, "aset expects array, got {s}", .{@tagName(current.tag())});
    const last_idx = indices[indices.len - 1];
    if (last_idx.tag() != .integer) return err.setErrorFmt(.eval, .type_error, .{}, "aset index must be integer, got {s}", .{@tagName(last_idx.tag())});
    const idx_i = last_idx.asInteger();
    const arr = current.asArray();
    if (idx_i < 0 or idx_i >= @as(i64, @intCast(arr.items.len))) {
        return err.setErrorFmt(.eval, .index_error, .{}, "Array index out of bounds: {d} (length {d})", .{ idx_i, arr.items.len });
    }
    arr.items[@intCast(idx_i)] = val;
    return val;
}

/// (alength array)
fn alengthFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to alength", .{args.len});
    if (args[0].tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, "alength expects array, got {s}", .{@tagName(args[0].tag())});
    return Value.initInteger(@intCast(args[0].asArray().items.len));
}

/// (aclone array)
fn acloneFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to aclone", .{args.len});
    if (args[0].tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, "aclone expects array, got {s}", .{@tagName(args[0].tag())});
    const src = args[0].asArray();
    const items = try allocator.alloc(Value, src.items.len);
    @memcpy(items, src.items);
    const arr = try allocator.create(ZigArray);
    arr.* = .{ .items = items, .element_type = src.element_type };
    return Value.initArray(arr);
}

/// (to-array coll) — converts any collection to Object array
fn toArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to to-array", .{args.len});
    if (args[0].tag() == .array) return args[0]; // already an array
    return collToArray(allocator, args[0]);
}

/// (into-array coll) or (into-array type coll) — type ignored in CW
fn intoArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1) return collToArray(allocator, args[0]);
    if (args.len == 2) return collToArray(allocator, args[1]); // ignore type arg
    return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to into-array", .{args.len});
}

// ============================================================
// Typed array constructors (Phase 43.2)
// ============================================================

/// Generic typed array constructor: (X-array size) or (X-array coll)
fn typedArrayFn(allocator: Allocator, args: []const Value, elem_type: ZigArray.ElementType, comptime name: []const u8) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to " ++ name, .{args.len});
    const arg = args[0];
    if (arg.tag() == .integer) {
        const size_i = arg.asInteger();
        if (size_i < 0) return err.setErrorFmt(.eval, .value_error, .{}, name ++ " size must be non-negative, got {d}", .{size_i});
        return createArray(allocator, @intCast(size_i), elem_type);
    }
    // Collection: convert to typed array
    const obj_arr = try collToArray(allocator, arg);
    obj_arr.asArray().element_type = elem_type;
    return obj_arr;
}

fn intArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .int, "int-array");
}
fn longArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .long, "long-array");
}
fn floatArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .float, "float-array");
}
fn doubleArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .double, "double-array");
}
fn booleanArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .boolean, "boolean-array");
}
fn byteArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .byte, "byte-array");
}
fn shortArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .short, "short-array");
}
fn charArrayFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return typedArrayFn(allocator, args, .char, "char-array");
}

/// (to-array-2d coll) — convert seq of seqs to 2D Object array
fn toArray2dFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to to-array-2d", .{args.len});
    // First convert outer to array of collections
    const outer = try collToArray(allocator, args[0]);
    const outer_arr = outer.asArray();
    // Convert each inner element to an array
    for (outer_arr.items) |*item| {
        if (item.tag() != .array) {
            item.* = try collToArray(allocator, item.*);
        }
    }
    return outer;
}

// ============================================================
// Type coercion functions (Phase 43.2)
// ============================================================

/// Generic coercion: assert array has expected element type, return identity.
fn coerceFn(comptime expected: ZigArray.ElementType, comptime name: []const u8) fn (Allocator, []const Value) anyerror!Value {
    return struct {
        fn f(_: Allocator, args: []const Value) anyerror!Value {
            if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to " ++ name, .{args.len});
            if (args[0].tag() != .array) return err.setErrorFmt(.eval, .type_error, .{}, name ++ " expects array, got {s}", .{@tagName(args[0].tag())});
            _ = expected; // CW does not enforce element types strictly, just returns identity
            return args[0];
        }
    }.f;
}

/// (bytes? x) — true if x is a byte array
fn bytesPredFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to bytes?", .{args.len});
    if (args[0].tag() != .array) return Value.false_val;
    return Value.initBoolean(args[0].asArray().element_type == .byte);
}

// ============================================================
// Builtin table
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "make-array",
        .func = makeArrayFn,
        .doc = "Creates and returns an array of Objects with the specified dimension(s).",
        .arglists = "([type dim] [type dim & more-dims])",
        .added = "1.0",
    },
    .{
        .name = "object-array",
        .func = objectArrayFn,
        .doc = "Creates an array of objects. If given a size, creates a nil-filled array. If given a collection, creates an array from its elements.",
        .arglists = "([size-or-seq])",
        .added = "1.2",
    },
    .{
        .name = "aget",
        .func = agetFn,
        .doc = "Returns the value at the index/indices. Works on arrays of any type.",
        .arglists = "([array idx] [array idx & idxs])",
        .added = "1.0",
    },
    .{
        .name = "aset",
        .func = asetFn,
        .doc = "Sets the value at the index/indices. Works on arrays of any type. Returns val.",
        .arglists = "([array idx val] [array idx idx2 & idxs])",
        .added = "1.0",
    },
    .{
        .name = "alength",
        .func = alengthFn,
        .doc = "Returns the length of the array.",
        .arglists = "([array])",
        .added = "1.0",
    },
    .{
        .name = "aclone",
        .func = acloneFn,
        .doc = "Returns a clone of the array.",
        .arglists = "([array])",
        .added = "1.0",
    },
    .{
        .name = "to-array",
        .func = toArrayFn,
        .doc = "Returns an array of Objects containing the contents of coll.",
        .arglists = "([coll])",
        .added = "1.0",
    },
    .{
        .name = "into-array",
        .func = intoArrayFn,
        .doc = "Returns an array with components set to the values in aseq.",
        .arglists = "([aseq] [type aseq])",
        .added = "1.0",
    },
    .{ .name = "int-array", .func = intArrayFn, .doc = "Creates an array of ints.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "long-array", .func = longArrayFn, .doc = "Creates an array of longs.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "float-array", .func = floatArrayFn, .doc = "Creates an array of floats.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "double-array", .func = doubleArrayFn, .doc = "Creates an array of doubles.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "boolean-array", .func = booleanArrayFn, .doc = "Creates an array of booleans.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "byte-array", .func = byteArrayFn, .doc = "Creates an array of bytes.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "short-array", .func = shortArrayFn, .doc = "Creates an array of shorts.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "char-array", .func = charArrayFn, .doc = "Creates an array of chars.", .arglists = "([size-or-seq])", .added = "1.0" },
    .{ .name = "to-array-2d", .func = toArray2dFn, .doc = "Returns a (potentially-ragged) 2-dimensional array of Objects.", .arglists = "([coll])", .added = "1.0" },
    .{ .name = "ints", .func = coerceFn(.int, "ints"), .doc = "Casts to int[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "longs", .func = coerceFn(.long, "longs"), .doc = "Casts to long[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "floats", .func = coerceFn(.float, "floats"), .doc = "Casts to float[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "doubles", .func = coerceFn(.double, "doubles"), .doc = "Casts to double[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "booleans", .func = coerceFn(.boolean, "booleans"), .doc = "Casts to boolean[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "bytes", .func = coerceFn(.byte, "bytes"), .doc = "Casts to byte[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "shorts", .func = coerceFn(.short, "shorts"), .doc = "Casts to short[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "chars", .func = coerceFn(.char, "chars"), .doc = "Casts to char[].", .arglists = "([xs])", .added = "1.0" },
    .{ .name = "aset-int", .func = asetFn, .doc = "Sets the value at the index of an int array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-long", .func = asetFn, .doc = "Sets the value at the index of a long array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-float", .func = asetFn, .doc = "Sets the value at the index of a float array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-double", .func = asetFn, .doc = "Sets the value at the index of a double array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-boolean", .func = asetFn, .doc = "Sets the value at the index of a boolean array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-byte", .func = asetFn, .doc = "Sets the value at the index of a byte array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-short", .func = asetFn, .doc = "Sets the value at the index of a short array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "aset-char", .func = asetFn, .doc = "Sets the value at the index of a char array.", .arglists = "([array idx val])", .added = "1.0" },
    .{ .name = "bytes?", .func = bytesPredFn, .doc = "Return true if x is a byte array.", .arglists = "([x])", .added = "1.9" },
};

// ============================================================
// Tests
// ============================================================

const testing = std.testing;

test "make-array creates nil-filled array" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Type symbol (ignored) + size
    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const result = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(3) });
    try testing.expectEqual(Value.Tag.array, result.tag());
    const arr = result.asArray();
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqual(Value.Tag.nil, arr.items[0].tag());
    try testing.expectEqual(Value.Tag.nil, arr.items[1].tag());
    try testing.expectEqual(Value.Tag.nil, arr.items[2].tag());
}

test "make-array multi-dim" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const result = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(2), Value.initInteger(3) });
    try testing.expectEqual(Value.Tag.array, result.tag());
    const arr = result.asArray();
    try testing.expectEqual(@as(usize, 2), arr.items.len);
    // Each element is a 3-element array
    try testing.expectEqual(Value.Tag.array, arr.items[0].tag());
    try testing.expectEqual(@as(usize, 3), arr.items[0].asArray().items.len);
}

test "aget and aset basic" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const arr_val = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(3) });

    // aset
    const val = try asetFn(alloc, &.{ arr_val, Value.initInteger(1), Value.initInteger(42) });
    try testing.expectEqual(@as(i64, 42), val.asInteger());

    // aget
    const got = try agetFn(alloc, &.{ arr_val, Value.initInteger(1) });
    try testing.expectEqual(@as(i64, 42), got.asInteger());

    // Other indices are still nil
    const nil_val = try agetFn(alloc, &.{ arr_val, Value.initInteger(0) });
    try testing.expectEqual(Value.Tag.nil, nil_val.tag());
}

test "alength" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const arr_val = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(5) });
    const len = try alengthFn(alloc, &.{arr_val});
    try testing.expectEqual(@as(i64, 5), len.asInteger());
}

test "aclone is independent copy" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const arr_val = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(2) });
    _ = try asetFn(alloc, &.{ arr_val, Value.initInteger(0), Value.initInteger(10) });

    const clone_val = try acloneFn(alloc, &.{arr_val});
    _ = try asetFn(alloc, &.{ clone_val, Value.initInteger(0), Value.initInteger(99) });

    // Original unchanged
    const orig = try agetFn(alloc, &.{ arr_val, Value.initInteger(0) });
    try testing.expectEqual(@as(i64, 10), orig.asInteger());
    // Clone has new value
    const cloned = try agetFn(alloc, &.{ clone_val, Value.initInteger(0) });
    try testing.expectEqual(@as(i64, 99), cloned.asInteger());
}

test "object-array from vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = try alloc.alloc(Value, 3);
    items[0] = Value.initInteger(1);
    items[1] = Value.initInteger(2);
    items[2] = Value.initInteger(3);
    const vec = try alloc.create(collections.PersistentVector);
    vec.* = .{ .items = items };
    const vec_val = Value.initVector(vec);

    const result = try objectArrayFn(alloc, &.{vec_val});
    try testing.expectEqual(Value.Tag.array, result.tag());
    const arr = result.asArray();
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqual(@as(i64, 1), arr.items[0].asInteger());
    try testing.expectEqual(@as(i64, 2), arr.items[1].asInteger());
    try testing.expectEqual(@as(i64, 3), arr.items[2].asInteger());
}

test "to-array passes through arrays" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Object" });
    const arr_val = try makeArrayFn(alloc, &.{ type_sym, Value.initInteger(2) });
    const result = try toArrayFn(alloc, &.{arr_val});
    // Should return same array (identity)
    try testing.expectEqual(arr_val.asArray(), result.asArray());
}

test "into-array from vector" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const items = try alloc.alloc(Value, 2);
    items[0] = Value.initInteger(10);
    items[1] = Value.initInteger(20);
    const vec = try alloc.create(collections.PersistentVector);
    vec.* = .{ .items = items };
    const vec_val = Value.initVector(vec);

    // 1-arg form
    const result = try intoArrayFn(alloc, &.{vec_val});
    try testing.expectEqual(Value.Tag.array, result.tag());
    try testing.expectEqual(@as(usize, 2), result.asArray().items.len);

    // 2-arg form (type + coll)
    const type_sym = Value.initSymbol(alloc, .{ .ns = null, .name = "Long" });
    const result2 = try intoArrayFn(alloc, &.{ type_sym, vec_val });
    try testing.expectEqual(Value.Tag.array, result2.tag());
    try testing.expectEqual(@as(usize, 2), result2.asArray().items.len);
}
