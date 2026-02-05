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

    /// Returns the actual stored element that equals val, or null.
    /// Unlike contains(), this returns the set's own element (preserving metadata).
    pub fn get(self: PersistentHashSet, val: Value) ?Value {
        for (self.items) |item| {
            if (item.eql(val)) return item;
        }
        return null;
    }
};

/// Transient vector — mutable builder for PersistentVector.
/// Created via (transient [1 2 3]), mutated via conj!/assoc!/pop!,
/// finalized via (persistent! tv).
pub const TransientVector = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
    consumed: bool = false,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentVector) !*TransientVector {
        const tv = try allocator.create(TransientVector);
        tv.* = .{};
        try tv.items.appendSlice(allocator, source.items);
        return tv;
    }

    pub fn ensureEditable(self: *TransientVector) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientVector) usize {
        return self.items.items.len;
    }

    pub fn conj(self: *TransientVector, allocator: std.mem.Allocator, val: Value) !*TransientVector {
        try self.ensureEditable();
        try self.items.append(allocator, val);
        return self;
    }

    pub fn assocAt(self: *TransientVector, allocator: std.mem.Allocator, index: usize, val: Value) !*TransientVector {
        try self.ensureEditable();
        if (index > self.items.items.len) return error.IndexOutOfBounds;
        if (index == self.items.items.len) {
            // Append at end (like assoc on vector with count as index)
            try self.items.append(allocator, val);
            return self;
        }
        self.items.items[index] = val;
        return self;
    }

    pub fn pop(self: *TransientVector) !*TransientVector {
        try self.ensureEditable();
        if (self.items.items.len == 0) return error.CantPopEmpty;
        _ = self.items.pop();
        return self;
    }

    pub fn persistent(self: *TransientVector, allocator: std.mem.Allocator) !*const PersistentVector {
        try self.ensureEditable();
        self.consumed = true;
        const items = try allocator.alloc(Value, self.items.items.len);
        @memcpy(items, self.items.items);
        const vec = try allocator.create(PersistentVector);
        vec.* = .{ .items = items };
        return vec;
    }
};

/// Transient array map — mutable builder for PersistentArrayMap.
pub const TransientArrayMap = struct {
    entries: std.ArrayListUnmanaged(Value) = .empty,
    consumed: bool = false,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentArrayMap) !*TransientArrayMap {
        const tm = try allocator.create(TransientArrayMap);
        tm.* = .{};
        try tm.entries.appendSlice(allocator, source.entries);
        return tm;
    }

    pub fn ensureEditable(self: *TransientArrayMap) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientArrayMap) usize {
        return self.entries.items.len / 2;
    }

    pub fn assocKV(self: *TransientArrayMap, allocator: std.mem.Allocator, key: Value, val: Value) !*TransientArrayMap {
        try self.ensureEditable();
        // Check if key already exists
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 2) {
            if (self.entries.items[i].eql(key)) {
                self.entries.items[i + 1] = val;
                return self;
            }
        }
        // New key — append
        try self.entries.append(allocator, key);
        try self.entries.append(allocator, val);
        return self;
    }

    pub fn dissocKey(self: *TransientArrayMap, key: Value) !*TransientArrayMap {
        try self.ensureEditable();
        var i: usize = 0;
        while (i < self.entries.items.len) : (i += 2) {
            if (self.entries.items[i].eql(key)) {
                // Swap-remove: move last pair into this slot
                const last = self.entries.items.len;
                if (i + 2 < last) {
                    self.entries.items[i] = self.entries.items[last - 2];
                    self.entries.items[i + 1] = self.entries.items[last - 1];
                }
                self.entries.items.len -= 2;
                return self;
            }
        }
        return self; // key not found — no-op
    }

    pub fn conjEntry(self: *TransientArrayMap, allocator: std.mem.Allocator, entry: Value) !*TransientArrayMap {
        try self.ensureEditable();
        // entry must be a vector of [key val]
        switch (entry) {
            .vector => |vec| {
                if (vec.items.len != 2) return error.MapEntryMustBePair;
                return self.assocKV(allocator, vec.items[0], vec.items[1]);
            },
            .map => |m| {
                // Merge map entries
                var i: usize = 0;
                while (i < m.entries.len) : (i += 2) {
                    _ = try self.assocKV(allocator, m.entries[i], m.entries[i + 1]);
                }
                return self;
            },
            else => return error.MapConjRequiresVectorOrMap,
        }
    }

    pub fn persistent(self: *TransientArrayMap, allocator: std.mem.Allocator) !*const PersistentArrayMap {
        try self.ensureEditable();
        self.consumed = true;
        const entries = try allocator.alloc(Value, self.entries.items.len);
        @memcpy(entries, self.entries.items);
        const m = try allocator.create(PersistentArrayMap);
        m.* = .{ .entries = entries };
        return m;
    }
};

/// Transient hash set — mutable builder for PersistentHashSet.
pub const TransientHashSet = struct {
    items: std.ArrayListUnmanaged(Value) = .empty,
    consumed: bool = false,

    pub fn initFrom(allocator: std.mem.Allocator, source: *const PersistentHashSet) !*TransientHashSet {
        const ts = try allocator.create(TransientHashSet);
        ts.* = .{};
        try ts.items.appendSlice(allocator, source.items);
        return ts;
    }

    pub fn ensureEditable(self: *TransientHashSet) !void {
        if (self.consumed) return error.TransientUsedAfterPersistent;
    }

    pub fn count(self: TransientHashSet) usize {
        return self.items.items.len;
    }

    pub fn conj(self: *TransientHashSet, allocator: std.mem.Allocator, val: Value) !*TransientHashSet {
        try self.ensureEditable();
        // Check for duplicate
        for (self.items.items) |item| {
            if (item.eql(val)) return self; // already present
        }
        try self.items.append(allocator, val);
        return self;
    }

    pub fn disj(self: *TransientHashSet, val: Value) !*TransientHashSet {
        try self.ensureEditable();
        for (self.items.items, 0..) |item, i| {
            if (item.eql(val)) {
                _ = self.items.swapRemove(i);
                return self;
            }
        }
        return self; // not found — no-op
    }

    pub fn persistent(self: *TransientHashSet, allocator: std.mem.Allocator) !*const PersistentHashSet {
        try self.ensureEditable();
        self.consumed = true;
        const items = try allocator.alloc(Value, self.items.items.len);
        @memcpy(items, self.items.items);
        const s = try allocator.create(PersistentHashSet);
        s.* = .{ .items = items };
        return s;
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
