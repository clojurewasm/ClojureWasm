//! Keyword interning for ClojureWasm runtime.
//!
//! Keywords are interned: identical keywords (same ns + name) share the same
//! heap pointer. This enables O(1) keyword equality via pointer comparison.
//! Thread-safe via mutex on the global intern table.

const std = @import("std");
const Value = @import("value.zig").Value;
const HeapHeader = @import("value.zig").HeapHeader;
const hash = @import("hash.zig");

/// Heap-allocated keyword. Prefixed with HeapHeader for GC.
pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    ns: ?[]const u8, // null for unqualified keywords
    name: []const u8,
    hash_cache: u32, // precomputed hash

    /// Format as ":ns/name" or ":name".
    pub fn formatQualified(self: *const Keyword, buf: []u8) []const u8 {
        const result = std.fmt.bufPrint(buf, ":{s}{s}{s}", .{
            if (self.ns) |n| n else "",
            if (self.ns != null) "/" else "",
            self.name,
        }) catch buf[0..@min(buf.len, 1)];
        return result;
    }
};

// --- Global intern table ---

var intern_table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty;
var intern_alloc: ?std.mem.Allocator = null;
var mutex: std.Thread.Mutex = .{};

/// Initialize the keyword intern system. Must be called before any interning.
pub fn init(alloc: std.mem.Allocator) void {
    intern_alloc = alloc;
}

/// Release all interned keywords.
pub fn deinit() void {
    const alloc = intern_alloc orelse return;
    // Free all owned key strings and keyword structs
    for (intern_table.keys(), intern_table.values()) |key, kw| {
        if (kw.ns) |n| alloc.free(n);
        alloc.free(kw.name);
        alloc.destroy(kw);
        alloc.free(key);
    }
    intern_table.deinit(alloc);
    intern_table = .empty;
    intern_alloc = null;
}

/// Intern a keyword. Returns the same pointer for identical ns+name pairs.
pub fn intern(ns: ?[]const u8, name: []const u8) !Value {
    const alloc = intern_alloc orelse return error.OutOfMemory;
    const key = try formatKey(alloc, ns, name);

    mutex.lock();
    defer mutex.unlock();

    if (intern_table.get(key)) |existing| {
        alloc.free(key); // key already exists
        return Value.encodeHeapPtr(.keyword, existing);
    }

    // Create new keyword
    const kw = try alloc.create(Keyword);
    kw.* = .{
        .header = HeapHeader.init(.keyword),
        .ns = if (ns) |n| (try alloc.dupe(u8, n)) else null,
        .name = try alloc.dupe(u8, name),
        .hash_cache = computeHash(ns, name),
    };

    try intern_table.put(alloc, key, kw);
    return Value.encodeHeapPtr(.keyword, kw);
}

/// Check if a keyword has been interned.
pub fn find(ns: ?[]const u8, name: []const u8) ?Value {
    const alloc = intern_alloc orelse return null;
    const key = formatKey(alloc, ns, name) catch return null;
    defer alloc.free(key);

    mutex.lock();
    defer mutex.unlock();

    if (intern_table.get(key)) |kw| {
        return Value.encodeHeapPtr(.keyword, kw);
    }
    return null;
}

/// Get the Keyword struct from a keyword Value.
pub fn asKeyword(val: Value) *const Keyword {
    std.debug.assert(val.tag() == .keyword);
    return val.decodePtr(*const Keyword);
}

// --- Internal helpers ---

fn formatKey(alloc: std.mem.Allocator, ns: ?[]const u8, name: []const u8) ![]u8 {
    if (ns) |n| {
        const key = try alloc.alloc(u8, n.len + 1 + name.len);
        @memcpy(key[0..n.len], n);
        key[n.len] = '/';
        @memcpy(key[n.len + 1 ..], name);
        return key;
    } else {
        return try alloc.dupe(u8, name);
    }
}

fn computeHash(ns: ?[]const u8, name: []const u8) u32 {
    if (ns) |n| {
        // Hash "ns/name" as a single string
        var h: u32 = hash.hashString(n);
        h = h *% 31 +% hash.hashString("/");
        h = h *% 31 +% hash.hashString(name);
        return h;
    } else {
        return hash.hashString(name);
    }
}

// --- Tests ---

const testing = std.testing;

test "intern creates keyword" {
    init(testing.allocator);
    defer deinit();

    const kw = try intern(null, "foo");
    try testing.expect(kw.tag() == .keyword);

    const k = asKeyword(kw);
    try testing.expect(k.ns == null);
    try testing.expectEqualStrings("foo", k.name);
}

test "intern returns same pointer for same keyword" {
    init(testing.allocator);
    defer deinit();

    const a = try intern(null, "bar");
    const b = try intern(null, "bar");
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));
}

test "intern different keywords are different" {
    init(testing.allocator);
    defer deinit();

    const a = try intern(null, "foo");
    const b = try intern(null, "bar");
    try testing.expect(@intFromEnum(a) != @intFromEnum(b));
}

test "intern with namespace" {
    init(testing.allocator);
    defer deinit();

    const kw = try intern("my.ns", "key");
    const k = asKeyword(kw);
    try testing.expectEqualStrings("my.ns", k.ns.?);
    try testing.expectEqualStrings("key", k.name);
}

test "namespace keywords are distinct from bare" {
    init(testing.allocator);
    defer deinit();

    const bare = try intern(null, "foo");
    const qualified = try intern("ns", "foo");
    try testing.expect(@intFromEnum(bare) != @intFromEnum(qualified));
}

test "find returns interned keyword" {
    init(testing.allocator);
    defer deinit();

    _ = try intern(null, "findme");
    const result = find(null, "findme");
    try testing.expect(result != null);
    try testing.expectEqualStrings("findme", asKeyword(result.?).name);
}

test "find returns null for unknown keyword" {
    init(testing.allocator);
    defer deinit();

    try testing.expect(find(null, "nonexistent") == null);
}

test "Keyword formatQualified" {
    init(testing.allocator);
    defer deinit();

    const bare = try intern(null, "foo");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(":foo", asKeyword(bare).formatQualified(&buf));

    const qualified = try intern("clojure.core", "map");
    try testing.expectEqualStrings(":clojure.core/map", asKeyword(qualified).formatQualified(&buf));
}

test "hash is precomputed" {
    init(testing.allocator);
    defer deinit();

    const kw = try intern(null, "test");
    const k = asKeyword(kw);
    try testing.expect(k.hash_cache != 0);
}

test "HeapHeader is correctly set" {
    init(testing.allocator);
    defer deinit();

    const kw = try intern(null, "x");
    const k = asKeyword(kw);
    try testing.expectEqual(@as(u8, @intFromEnum(@import("value.zig").HeapTag.keyword)), k.header.tag);
}
