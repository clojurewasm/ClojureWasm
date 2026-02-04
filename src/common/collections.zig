// Persistent collection types for ClojureWasm.
//
// Initial implementation: array-based (ArrayList-style slices).
// Future: cons cells (List), 32-way trie (Vector), HAMT (Map/Set).

const std = @import("std");
const Value = @import("value.zig").Value;

const testing = std.testing;

/// Persistent list — array-backed for initial simplicity.
pub const PersistentList = struct {
    items: []const Value,
    meta: ?*const Value = null,
    source_line: u32 = 0,
    source_column: u16 = 0,
    /// Per-child source positions for macro expansion roundtrip preservation.
    /// Parallel to items[]. Set by formToValue, read by valueToForm.
    child_lines: ?[]const u32 = null,
    child_columns: ?[]const u16 = null,

    pub fn count(self: PersistentList) usize {
        return self.items.len;
    }

    pub fn first(self: PersistentList) Value {
        if (self.items.len == 0) return .nil;
        return self.items[0];
    }

    pub fn rest(self: PersistentList) PersistentList {
        if (self.items.len == 0) return .{ .items = &.{} };
        return .{ .items = self.items[1..] };
    }
};

/// Persistent vector — array-backed for initial simplicity.
pub const PersistentVector = struct {
    items: []const Value,
    meta: ?*const Value = null,
    source_line: u32 = 0,
    source_column: u16 = 0,
    /// Per-child source positions for macro expansion roundtrip preservation.
    child_lines: ?[]const u32 = null,
    child_columns: ?[]const u16 = null,

    pub fn count(self: PersistentVector) usize {
        return self.items.len;
    }

    pub fn nth(self: PersistentVector, index: usize) ?Value {
        if (index >= self.items.len) return null;
        return self.items[index];
    }
};

/// Persistent array map — flat key-value pairs [k1,v1,k2,v2,...].
/// Insertion-order preserving. Linear scan for lookup.
pub const PersistentArrayMap = struct {
    entries: []const Value,
    meta: ?*const Value = null,

    pub fn count(self: PersistentArrayMap) usize {
        return self.entries.len / 2;
    }

    pub fn get(self: PersistentArrayMap, key: Value) ?Value {
        var i: usize = 0;
        while (i < self.entries.len) : (i += 2) {
            if (self.entries[i].eql(key)) return self.entries[i + 1];
        }
        return null;
    }
};

/// Persistent hash set — array-backed with linear scan.
pub const PersistentHashSet = struct {
    items: []const Value,
    meta: ?*const Value = null,

    pub fn count(self: PersistentHashSet) usize {
        return self.items.len;
    }

    pub fn contains(self: PersistentHashSet, val: Value) bool {
        for (self.items) |item| {
            if (item.eql(val)) return true;
        }
        return false;
    }
};

// === Tests ===

test "PersistentList - empty" {
    const list = PersistentList{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), list.count());
}

test "PersistentList - count/first/rest" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const list = PersistentList{ .items = &items };
    try testing.expectEqual(@as(usize, 3), list.count());
    try testing.expect(list.first().eql(.{ .integer = 1 }));
    try testing.expectEqual(@as(usize, 2), list.rest().count());
}

test "PersistentList - first of empty is nil" {
    const list = PersistentList{ .items = &.{} };
    try testing.expect(list.first().isNil());
}

test "PersistentList - rest of empty is empty list" {
    const list = PersistentList{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), list.rest().count());
}

test "PersistentVector - empty" {
    const vec = PersistentVector{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), vec.count());
}

test "PersistentVector - count/nth" {
    const items = [_]Value{ .{ .integer = 10 }, .{ .integer = 20 }, .{ .integer = 30 } };
    const vec = PersistentVector{ .items = &items };
    try testing.expectEqual(@as(usize, 3), vec.count());
    try testing.expect(vec.nth(0).?.eql(.{ .integer = 10 }));
    try testing.expect(vec.nth(1).?.eql(.{ .integer = 20 }));
    try testing.expect(vec.nth(2).?.eql(.{ .integer = 30 }));
    try testing.expect(vec.nth(3) == null);
}

test "PersistentArrayMap - empty" {
    const m = PersistentArrayMap{ .entries = &.{} };
    try testing.expectEqual(@as(usize, 0), m.count());
}

test "PersistentArrayMap - count/get" {
    // {k1 v1, k2 v2} stored as [k1, v1, k2, v2]
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
        .{ .keyword = .{ .name = "b", .ns = null } }, .{ .integer = 2 },
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try testing.expectEqual(@as(usize, 2), m.count());
    const v = m.get(.{ .keyword = .{ .name = "a", .ns = null } });
    try testing.expect(v != null);
    try testing.expect(v.?.eql(.{ .integer = 1 }));
}

test "PersistentArrayMap - get missing key" {
    const entries = [_]Value{
        .{ .keyword = .{ .name = "a", .ns = null } }, .{ .integer = 1 },
    };
    const m = PersistentArrayMap{ .entries = &entries };
    try testing.expect(m.get(.{ .keyword = .{ .name = "z", .ns = null } }) == null);
}

test "PersistentHashSet - empty" {
    const s = PersistentHashSet{ .items = &.{} };
    try testing.expectEqual(@as(usize, 0), s.count());
}

test "PersistentHashSet - contains" {
    const items = [_]Value{ .{ .integer = 1 }, .{ .integer = 2 }, .{ .integer = 3 } };
    const s = PersistentHashSet{ .items = &items };
    try testing.expectEqual(@as(usize, 3), s.count());
    try testing.expect(s.contains(.{ .integer = 2 }));
    try testing.expect(!s.contains(.{ .integer = 99 }));
}
