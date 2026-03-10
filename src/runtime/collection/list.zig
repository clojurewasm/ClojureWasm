//! PersistentList — Clojure's singly-linked cons cell list.
//!
//! Each Cons cell holds `first` (head value), `rest` (tail: nil or another list),
//! `meta` (nil or metadata map), and `count` (O(1) length).
//! Lists are immutable and structurally shared.

const std = @import("std");
const Value = @import("../value.zig").Value;
const HeapHeader = @import("../value.zig").HeapHeader;

/// Cons cell — the fundamental list building block.
/// Heap-allocated, 8-byte aligned for NaN boxing pointer encoding.
pub const Cons = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined, // align first to 8 bytes
    first: Value,
    rest: Value, // nil or pointer to another Cons
    meta: Value, // nil or metadata map
    count: u32,

    comptime {
        // Verify first/rest are at 8-byte aligned offsets
        std.debug.assert(@alignOf(Cons) >= 8);
    }
};

/// Allocate a new cons cell prepending `head` to `tail`.
/// `tail` must be nil or a list Value.
pub fn cons(alloc: std.mem.Allocator, head: Value, tail: Value) !Value {
    const cell = try alloc.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),
    };
    return Value.encodeHeapPtr(.list, cell);
}

/// Get the first element of a list. Returns nil for nil.
pub fn first(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).first,
        else => .nil_val,
    };
}

/// Get the rest of a list. Returns nil for nil or single-element lists.
pub fn rest(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).rest,
        else => .nil_val,
    };
}

/// Get the count of a list. Returns 0 for nil.
pub fn countOf(val: Value) u32 {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).count,
        else => 0,
    };
}

/// Return the value as a sequence (itself if non-empty, nil if empty).
pub fn seq(val: Value) Value {
    return switch (val.tag()) {
        .list => if (val.decodePtr(*Cons).count > 0) val else .nil_val,
        else => .nil_val,
    };
}

/// Get the raw Cons pointer from a list Value.
pub fn asCons(val: Value) *Cons {
    std.debug.assert(val.tag() == .list);
    return val.decodePtr(*Cons);
}

// --- Tests ---

const testing = std.testing;

test "Cons struct alignment" {
    try testing.expect(@alignOf(Cons) >= 8);
}

test "cons creates single-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const val = Value.initInteger(42);
    const lst = try cons(alloc, val, .nil_val);

    try testing.expect(lst.tag() == .list);
    try testing.expectEqual(@as(u32, 1), countOf(lst));

    const head = first(lst);
    try testing.expect(head.tag() == .integer);
    try testing.expectEqual(@as(i48, 42), head.asInteger());

    try testing.expect(rest(lst).isNil());
}

test "cons creates multi-element list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Build (1 2 3) as cons(1, cons(2, cons(3, nil)))
    const l3 = try cons(alloc, Value.initInteger(3), .nil_val);
    const l2 = try cons(alloc, Value.initInteger(2), l3);
    const l1 = try cons(alloc, Value.initInteger(1), l2);

    try testing.expectEqual(@as(u32, 3), countOf(l1));
    try testing.expectEqual(@as(u32, 2), countOf(l2));
    try testing.expectEqual(@as(u32, 1), countOf(l3));

    try testing.expectEqual(@as(i48, 1), first(l1).asInteger());
    try testing.expectEqual(@as(i48, 2), first(rest(l1)).asInteger());
    try testing.expectEqual(@as(i48, 3), first(rest(rest(l1))).asInteger());
    try testing.expect(rest(rest(rest(l1))).isNil());
}

test "first/rest of nil" {
    try testing.expect(first(.nil_val).isNil());
    try testing.expect(rest(.nil_val).isNil());
    try testing.expectEqual(@as(u32, 0), countOf(.nil_val));
}

test "seq returns self for non-empty, nil for empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, Value.initInteger(1), .nil_val);
    try testing.expect(!seq(lst).isNil());
    try testing.expect(seq(.nil_val).isNil());
}

test "cons preserves HeapHeader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, .true_val, .nil_val);
    const cell = asCons(lst);
    try testing.expectEqual(@as(u8, @intFromEnum(@import("../value.zig").HeapTag.list)), cell.header.tag);
    try testing.expect(!cell.header.flags.marked);
    try testing.expect(!cell.header.flags.frozen);
}

test "meta defaults to nil" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const lst = try cons(alloc, Value.initInteger(1), .nil_val);
    try testing.expect(asCons(lst).meta.isNil());
}

test "structural sharing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // (2 3)
    const tail = try cons(alloc, Value.initInteger(2),
        try cons(alloc, Value.initInteger(3), .nil_val));

    // (1 2 3) shares tail with (0 2 3)
    const a = try cons(alloc, Value.initInteger(1), tail);
    const b = try cons(alloc, Value.initInteger(0), tail);

    // Both share the same tail pointer
    try testing.expectEqual(@intFromEnum(rest(a)), @intFromEnum(rest(b)));
    try testing.expectEqual(@as(u32, 3), countOf(a));
    try testing.expectEqual(@as(u32, 3), countOf(b));
}
