//! Keyword interning — Phase-1 single-threaded stub.
//!
//! Keywords are interned: identical (ns, name) pairs share one heap
//! pointer, so equality reduces to a pointer comparison.
//!
//! ### Phase-1 scope
//!
//! This is a self-contained `KeywordInterner` that owns its allocator
//! and table. Phase 2.0 widens the public API to take a `*Runtime` and
//! wraps the table with `std.Io.Mutex.lockUncancelable(rt.io)`. Pinning
//! the *struct shape* now (header + ns + name + hash_cache) means
//! Phase 2.0 only changes call sites, not memory layout.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const hash = @import("hash.zig");

/// Heap-allocated keyword. Layout-stable across Phase 1 → Phase 2.0
/// (Phase 2.0 only changes how the interner is reached, not the cell).
pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    /// Null for unqualified keywords like `:foo`.
    ns: ?[]const u8,
    name: []const u8,
    /// Precomputed Murmur3 hash of `ns/name` (or just `name`).
    hash_cache: u32,

    /// Format as `:ns/name` or `:name`. Returns a slice of `buf`.
    pub fn formatQualified(self: *const Keyword, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, ":{s}{s}{s}", .{
            if (self.ns) |n| n else "",
            if (self.ns != null) "/" else "",
            self.name,
        }) catch buf[0..@min(buf.len, 1)];
    }
};

/// Process-unique keyword table. Phase-1 single-threaded; Phase 2.0
/// embeds a `std.Io.Mutex` and switches `intern` / `find` to take
/// `*Runtime` rather than `*KeywordInterner` directly.
pub const KeywordInterner = struct {
    /// Backing allocator for both the table and the interned strings.
    /// In Phase-2 production this will equal `Runtime.gpa`.
    alloc: std.mem.Allocator,
    /// Composite key (`"ns/name"` or `"name"`) → `*Keyword`.
    table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,

    pub fn init(alloc: std.mem.Allocator) KeywordInterner {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *KeywordInterner) void {
        for (self.table.keys(), self.table.values()) |key, kw| {
            if (kw.ns) |n| self.alloc.free(n);
            self.alloc.free(kw.name);
            self.alloc.destroy(kw);
            self.alloc.free(key);
        }
        self.table.deinit(self.alloc);
        self.table = .empty;
    }

    /// Intern `(ns, name)`. Identical inputs always return the same
    /// pointer-equal Value.
    pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value {
        const key = try formatKey(self.alloc, ns, name);

        if (self.table.get(key)) |existing| {
            self.alloc.free(key);
            return Value.encodeHeapPtr(.keyword, existing);
        }

        const kw = try self.alloc.create(Keyword);
        kw.* = .{
            .header = HeapHeader.init(.keyword),
            .ns = if (ns) |n| (try self.alloc.dupe(u8, n)) else null,
            .name = try self.alloc.dupe(u8, name),
            .hash_cache = computeHash(ns, name),
        };

        try self.table.put(self.alloc, key, kw);
        return Value.encodeHeapPtr(.keyword, kw);
    }

    /// Lookup without insertion. Returns `null` if not yet interned.
    pub fn find(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) ?Value {
        const key = formatKey(self.alloc, ns, name) catch return null;
        defer self.alloc.free(key);

        if (self.table.get(key)) |kw| {
            return Value.encodeHeapPtr(.keyword, kw);
        }
        return null;
    }
};

/// Decode a keyword Value to a `*const Keyword`. No table lookup.
pub fn asKeyword(val: Value) *const Keyword {
    std.debug.assert(val.tag() == .keyword);
    return val.decodePtr(*const Keyword);
}

// --- internal helpers ---

fn formatKey(alloc: std.mem.Allocator, ns: ?[]const u8, name: []const u8) ![]u8 {
    if (ns) |n| {
        const key = try alloc.alloc(u8, n.len + 1 + name.len);
        @memcpy(key[0..n.len], n);
        key[n.len] = '/';
        @memcpy(key[n.len + 1 ..], name);
        return key;
    }
    return try alloc.dupe(u8, name);
}

fn computeHash(ns: ?[]const u8, name: []const u8) u32 {
    if (ns) |n| {
        var h: u32 = hash.hashString(n);
        h = h *% 31 +% hash.hashString("/");
        h = h *% 31 +% hash.hashString(name);
        return h;
    }
    return hash.hashString(name);
}

// --- tests ---

const testing = std.testing;

test "intern creates a keyword Value" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.intern(null, "foo");
    try testing.expect(kw.tag() == .keyword);

    const k = asKeyword(kw);
    try testing.expect(k.ns == null);
    try testing.expectEqualStrings("foo", k.name);
}

test "intern returns the same pointer for repeats" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const a = try interner.intern(null, "bar");
    const b = try interner.intern(null, "bar");
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));
}

test "different keywords have different pointers" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const a = try interner.intern(null, "foo");
    const b = try interner.intern(null, "bar");
    try testing.expect(@intFromEnum(a) != @intFromEnum(b));
}

test "qualified keywords are distinct from bare" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const bare = try interner.intern(null, "foo");
    const qualified = try interner.intern("ns", "foo");
    try testing.expect(@intFromEnum(bare) != @intFromEnum(qualified));

    const k = asKeyword(qualified);
    try testing.expectEqualStrings("ns", k.ns.?);
    try testing.expectEqualStrings("foo", k.name);
}

test "find returns interned keyword and null for missing" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    _ = try interner.intern(null, "findme");
    const result = interner.find(null, "findme");
    try testing.expect(result != null);
    try testing.expectEqualStrings("findme", asKeyword(result.?).name);

    try testing.expect(interner.find(null, "nonexistent") == null);
}

test "formatQualified renders both bare and qualified" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const bare = try interner.intern(null, "foo");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(":foo", asKeyword(bare).formatQualified(&buf));

    const qualified = try interner.intern("clojure.core", "map");
    try testing.expectEqualStrings(":clojure.core/map", asKeyword(qualified).formatQualified(&buf));
}

test "hash_cache is precomputed and non-trivial" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.intern(null, "test");
    try testing.expect(asKeyword(kw).hash_cache != 0);
}

test "HeapHeader carries the keyword tag" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.intern(null, "x");
    const k = asKeyword(kw);
    try testing.expectEqual(@as(u8, @intFromEnum(HeapTag.keyword)), k.header.tag);
}

test "two interners are independent (no global table)" {
    var a = KeywordInterner.init(testing.allocator);
    defer a.deinit();
    var b = KeywordInterner.init(testing.allocator);
    defer b.deinit();

    const ka = try a.intern(null, "foo");
    const kb = try b.intern(null, "foo");
    try testing.expect(@intFromEnum(ka) != @intFromEnum(kb));
}
