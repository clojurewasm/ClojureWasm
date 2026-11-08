// SPDX-License-Identifier: EPL-2.0
//! Keyword interning (rt-aware).
//!
//! Keywords are interned: identical (ns, name) pairs share one heap
//! pointer, so equality reduces to a pointer comparison.
//!
//! ### Two-entry (unlocked + locked) shape
//!
//! `KeywordInterner.intern(self, ns, name)` is the low-level method
//! (so single-threaded tests and tooling can drive the table without
//! going through a Runtime); the top-level `intern(rt, ns, name)` /
//! `find(rt, ns, name)` acquire `std.Io.Mutex.lockUncancelable(rt.io)`
//! around the call. The cell layout is header + ns + name + hash_cache.
//!
//! ### Why a mutex when the runtime is still single-threaded?
//!
//! Wiring `std.Io.Mutex` through the call site now means the Phase B
//! concurrency rollout doesn't need to touch this file — the lock just
//! starts blocking. The cost today is one uncontended
//! `lockUncancelable` per intern, on the order of a load + store.

const std = @import("std");
const value = @import("value/value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const hash = @import("hash.zig");
const Runtime = @import("runtime.zig").Runtime;

/// Heap-allocated keyword. The cell layout is independent of how the
/// interner is reached (locked top-level vs unlocked method entry).
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

/// Process-unique keyword table. Owned by `Runtime.keywords`.
pub const KeywordInterner = struct {
    /// Backing allocator. In production this aliases `Runtime.gpa`.
    alloc: std.mem.Allocator,
    /// Composite key (`"ns/name"` or `"name"`) → `*Keyword`.
    table: std.array_hash_map.String(*Keyword) = .empty,
    /// Guards `table` against concurrent intern / find calls. The
    /// runtime is single-threaded today so this is effectively free;
    /// wiring it now means the Phase B concurrency rollout doesn't need
    /// to touch this file.
    mutex: std.Io.Mutex = .init,

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

    /// Low-level intern — does **not** lock. Most callers should use
    /// the top-level `intern(rt, ns, name)` instead, which acquires
    /// `mutex` first. This entry is preserved for callers that
    /// already hold the lock or are running in a known-single-threaded
    /// path (tests, fixed-input bootstrap).
    pub fn internUnlocked(self: *KeywordInterner, ns: ?[]const u8, name_: []const u8) !Value {
        // PERF: probe with a stack-built key first; the hit path (re-interning
        // an existing keyword, e.g. `(keyword (str "k" i))` in a loop) then
        // allocates nothing. [refs: O-076]
        var kbuf: [128]u8 = undefined;
        if (stackKey(&kbuf, ns, name_)) |probe| {
            if (self.table.get(probe)) |existing| return Value.encodeHeapPtr(.keyword, existing);
        }
        const key = try formatKey(self.alloc, ns, name_);

        if (self.table.get(key)) |existing| {
            self.alloc.free(key);
            return Value.encodeHeapPtr(.keyword, existing);
        }

        const kw = try self.alloc.create(Keyword);
        kw.* = .{
            .header = HeapHeader.init(.keyword),
            .ns = if (ns) |n| (try self.alloc.dupe(u8, n)) else null,
            .name = try self.alloc.dupe(u8, name_),
            .hash_cache = computeHash(ns, name_),
        };

        try self.table.put(self.alloc, key, kw);
        return Value.encodeHeapPtr(.keyword, kw);
    }

    /// Low-level lookup — does not lock. See `internUnlocked` for
    /// when to prefer this over the rt-aware top-level `find`.
    pub fn findUnlocked(self: *KeywordInterner, ns: ?[]const u8, name_: []const u8) ?Value {
        var kbuf: [128]u8 = undefined;
        if (stackKey(&kbuf, ns, name_)) |probe| {
            return if (self.table.get(probe)) |kw| Value.encodeHeapPtr(.keyword, kw) else null;
        }
        const key = formatKey(self.alloc, ns, name_) catch return null;
        defer self.alloc.free(key);

        if (self.table.get(key)) |kw| {
            return Value.encodeHeapPtr(.keyword, kw);
        }
        return null;
    }
};

/// Intern `(ns, name)` against `rt.keywords`, locking via `rt.io`.
pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.internUnlocked(ns, name_);
}

/// Look up an existing interning. Returns `null` if not yet present.
pub fn find(rt: *Runtime, ns: ?[]const u8, name_: []const u8) ?Value {
    rt.keywords.mutex.lockUncancelable(rt.io);
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.findUnlocked(ns, name_);
}

/// Decode a keyword Value to a `*const Keyword`. No table lookup —
/// pure pointer arithmetic, so no lock needed.
pub fn asKeyword(val: Value) *const Keyword {
    std.debug.assert(val.tag() == .keyword);
    return val.decodePtr(*const Keyword);
}

// --- internal helpers ---

/// `formatKey` into a caller buffer; null when the key does not fit.
fn stackKey(buf: []u8, ns: ?[]const u8, name_: []const u8) ?[]const u8 {
    if (ns) |n| {
        const len = n.len + 1 + name_.len;
        if (len > buf.len) return null;
        @memcpy(buf[0..n.len], n);
        buf[n.len] = '/';
        @memcpy(buf[n.len + 1 ..][0..name_.len], name_);
        return buf[0..len];
    }
    // No ns: the key IS the name; no copy needed.
    return name_;
}

fn formatKey(alloc: std.mem.Allocator, ns: ?[]const u8, name_: []const u8) ![]u8 {
    if (ns) |n| {
        const key = try alloc.alloc(u8, n.len + 1 + name_.len);
        @memcpy(key[0..n.len], n);
        key[n.len] = '/';
        @memcpy(key[n.len + 1 ..], name_);
        return key;
    }
    return try alloc.dupe(u8, name_);
}

fn computeHash(ns: ?[]const u8, name_: []const u8) u32 {
    // clojure.lang.Symbol.hasheq: hashCombine(Murmur3.hashUnencodedChars(name),
    // ns String.hashCode or 0) — the portable clj hash value (a Keyword adds
    // 0x9e3779b9 on top at the valueHash layer, = Keyword.hasheq).
    const ns_hash: u32 = if (ns) |n| @bitCast(hash.javaStringHashCode(n)) else 0;
    return hash.hashCombine(hash.hashUnencodedChars(name_), ns_hash);
}

// --- tests ---

const testing = std.testing;

const TestFixture = struct {
    threaded: std.Io.Threaded,
    rt: Runtime,

    fn init(self: *TestFixture, alloc: std.mem.Allocator) void {
        self.threaded = std.Io.Threaded.init(alloc, .{});
        self.rt = Runtime.init(self.threaded.io(), alloc);
    }

    fn deinit(self: *TestFixture) void {
        self.rt.deinit();
        self.threaded.deinit();
    }
};

// --- low-level interner tests (unchanged from Phase 1) ---

test "internUnlocked creates a keyword Value" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.internUnlocked(null, "foo");
    try testing.expect(kw.tag() == .keyword);

    const k = asKeyword(kw);
    try testing.expect(k.ns == null);
    try testing.expectEqualStrings("foo", k.name);
}

test "internUnlocked returns the same pointer for repeats" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const a = try interner.internUnlocked(null, "bar");
    const b = try interner.internUnlocked(null, "bar");
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));
}

test "qualified keywords are distinct from bare via internUnlocked" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const bare = try interner.internUnlocked(null, "foo");
    const qualified = try interner.internUnlocked("ns", "foo");
    try testing.expect(@intFromEnum(bare) != @intFromEnum(qualified));

    const k = asKeyword(qualified);
    try testing.expectEqualStrings("ns", k.ns.?);
    try testing.expectEqualStrings("foo", k.name);
}

test "findUnlocked: hits an interned keyword, misses an unknown one" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    _ = try interner.internUnlocked(null, "findme");
    const result = interner.findUnlocked(null, "findme");
    try testing.expect(result != null);
    try testing.expectEqualStrings("findme", asKeyword(result.?).name);

    try testing.expect(interner.findUnlocked(null, "nonexistent") == null);
}

test "formatQualified renders both bare and qualified" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const bare = try interner.internUnlocked(null, "foo");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(":foo", asKeyword(bare).formatQualified(&buf));

    const qualified = try interner.internUnlocked("clojure.core", "map");
    try testing.expectEqualStrings(":clojure.core/map", asKeyword(qualified).formatQualified(&buf));
}

test "hash_cache is precomputed" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.internUnlocked(null, "test");
    try testing.expect(asKeyword(kw).hash_cache != 0);
}

test "HeapHeader carries the keyword tag" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const kw = try interner.internUnlocked(null, "x");
    try testing.expectEqual(@as(u8, @intFromEnum(HeapTag.keyword)), asKeyword(kw).header.tag);
}

// --- rt-aware tests (Phase 2.2 surface) ---

test "intern(rt, ...) creates a keyword and round-trips" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const kw = try intern(&fix.rt, null, "foo");
    try testing.expect(kw.tag() == .keyword);
    try testing.expectEqualStrings("foo", asKeyword(kw).name);
}

test "intern(rt, ...) is idempotent across calls" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    const a = try intern(&fix.rt, null, "bar");
    const b = try intern(&fix.rt, null, "bar");
    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));
}

test "find(rt, ...) returns interned and null for missing" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    _ = try intern(&fix.rt, null, "findme");
    const hit = find(&fix.rt, null, "findme");
    try testing.expect(hit != null);
    try testing.expectEqualStrings("findme", asKeyword(hit.?).name);

    try testing.expect(find(&fix.rt, null, "nope") == null);
}

test "two Runtimes maintain independent keyword tables" {
    var fix1: TestFixture = undefined;
    fix1.init(testing.allocator);
    defer fix1.deinit();
    var fix2: TestFixture = undefined;
    fix2.init(testing.allocator);
    defer fix2.deinit();

    const k1 = try intern(&fix1.rt, null, "shared");
    const k2 = try intern(&fix2.rt, null, "shared");
    // Same name, different process-wide tables → distinct pointers.
    try testing.expect(@intFromEnum(k1) != @intFromEnum(k2));
}
