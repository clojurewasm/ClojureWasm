// SPDX-License-Identifier: EPL-2.0
//! Bencode wire-format codec — namespace-neutral per F-009.
//!
//! Bencode is the BitTorrent wire format ([spec][1]) that nREPL
//! adopted for its transport layer. cw v1 row 14.10 uses it for the
//! `cljw nrepl` server only today; future EDN-over-WebSocket and pod
//! transports may also call here.
//!
//! Supports four types from the spec:
//! - `i<int>e` — signed integer (cw v1 limits to i64).
//! - `<len>:<bytes>` — byte string (length-prefixed, no UTF-8
//!   guarantee at the codec level; the caller interprets).
//! - `l<elements>e` — list (heterogeneous element types).
//! - `d<key1><val1>...e` — dict; keys MUST be strings + sorted
//!   lexically per spec. cw v1 enforces sort on encode (decode
//!   accepts any order for robustness).
//!
//! [1]: https://wiki.theory.org/BitTorrentSpecification#Bencoding
//!
//! Memory model: `Decoded` is a tagged union over arena-owned
//! slices. Caller passes the arena to `decode`; the returned
//! `Decoded` tree lives until the arena is freed (the per-request
//! arena is the typical scope). Encode writes to a
//! `std.Io.Writer.Allocating` and returns the owned byte slice.

const std = @import("std");
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;

pub const Decoded = union(enum) {
    int: i64,
    str: []const u8,
    list: []const Decoded,
    /// Dict entries flattened to alternating key/value pairs. Keys
    /// are always strings; flattening keeps `Decoded` recursive
    /// without an extra pair struct.
    dict: []const Entry,

    pub const Entry = struct { key: []const u8, value: Decoded };
};

pub const DecodeError = error{
    UnexpectedEof,
    InvalidPrefix,
    InvalidIntegerSyntax,
    NegativeLength,
    OutOfMemory,
};

/// Decode a single bencode value from `bytes` starting at offset 0.
/// Returns the decoded value + bytes consumed.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) DecodeError!struct { value: Decoded, consumed: usize } {
    var state: DecodeState = .{ .bytes = bytes, .offset = 0, .arena = arena };
    const v = try state.readOne();
    return .{ .value = v, .consumed = state.offset };
}

const DecodeState = struct {
    bytes: []const u8,
    offset: usize,
    arena: std.mem.Allocator,

    fn peek(self: *DecodeState) DecodeError!u8 {
        if (self.offset >= self.bytes.len) return error.UnexpectedEof;
        return self.bytes[self.offset];
    }

    fn advance(self: *DecodeState) void {
        self.offset += 1;
    }

    fn readOne(self: *DecodeState) DecodeError!Decoded {
        const c = try self.peek();
        return switch (c) {
            'i' => try self.readInt(),
            'l' => try self.readList(),
            'd' => try self.readDict(),
            '0'...'9' => try self.readString(),
            else => error.InvalidPrefix,
        };
    }

    fn readInt(self: *DecodeState) DecodeError!Decoded {
        self.advance(); // 'i'
        const start = self.offset;
        while (self.offset < self.bytes.len and self.bytes[self.offset] != 'e') : (self.offset += 1) {}
        if (self.offset >= self.bytes.len) return error.UnexpectedEof;
        const num_bytes = self.bytes[start..self.offset];
        self.advance(); // 'e'
        const n = std.fmt.parseInt(i64, num_bytes, 10) catch return error.InvalidIntegerSyntax;
        return .{ .int = n };
    }

    fn readString(self: *DecodeState) DecodeError!Decoded {
        const start = self.offset;
        while (self.offset < self.bytes.len and self.bytes[self.offset] != ':') : (self.offset += 1) {}
        if (self.offset >= self.bytes.len) return error.UnexpectedEof;
        const len_bytes = self.bytes[start..self.offset];
        const length = std.fmt.parseInt(usize, len_bytes, 10) catch return error.InvalidIntegerSyntax;
        self.advance(); // ':'
        if (self.offset + length > self.bytes.len) return error.UnexpectedEof;
        const slice = self.bytes[self.offset .. self.offset + length];
        self.offset += length;
        return .{ .str = slice };
    }

    fn readList(self: *DecodeState) DecodeError!Decoded {
        self.advance(); // 'l'
        var items: std.ArrayList(Decoded) = .empty;
        defer items.deinit(self.arena);
        while (true) {
            const c = try self.peek();
            if (c == 'e') {
                self.advance();
                break;
            }
            try items.append(self.arena, try self.readOne());
        }
        return .{ .list = try self.arena.dupe(Decoded, items.items) };
    }

    fn readDict(self: *DecodeState) DecodeError!Decoded {
        self.advance(); // 'd'
        var entries: std.ArrayList(Decoded.Entry) = .empty;
        defer entries.deinit(self.arena);
        while (true) {
            const c = try self.peek();
            if (c == 'e') {
                self.advance();
                break;
            }
            const key = try self.readOne();
            if (key != .str) return error.InvalidPrefix;
            const val = try self.readOne();
            try entries.append(self.arena, .{ .key = key.str, .value = val });
        }
        return .{ .dict = try self.arena.dupe(Decoded.Entry, entries.items) };
    }
};

/// Encode `v` into a freshly-allocated byte slice owned by `alloc`.
/// Dicts are sorted lexically per spec.
pub fn encode(alloc: std.mem.Allocator, v: Decoded) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try writeOne(&out.writer, v, alloc);
    return out.toOwnedSlice();
}

fn writeOne(w: *Writer, v: Decoded, alloc: std.mem.Allocator) !void {
    switch (v) {
        .int => |n| try w.print("i{d}e", .{n}),
        .str => |s| try w.print("{d}:{s}", .{ s.len, s }),
        .list => |items| {
            try w.writeByte('l');
            for (items) |item| try writeOne(w, item, alloc);
            try w.writeByte('e');
        },
        .dict => |entries| {
            // Sort by key per spec; dupe to avoid mutating caller's
            // slice. (Skip for already-sorted typical case via test
            // first — small N so unconditional sort is cheap.)
            const sorted = try alloc.dupe(Decoded.Entry, entries);
            defer alloc.free(sorted);
            std.mem.sort(Decoded.Entry, sorted, {}, struct {
                fn lt(_: void, a: Decoded.Entry, b: Decoded.Entry) bool {
                    return std.mem.order(u8, a.key, b.key) == .lt;
                }
            }.lt);
            try w.writeByte('d');
            for (sorted) |e| {
                try w.print("{d}:{s}", .{ e.key.len, e.key });
                try writeOne(w, e.value, alloc);
            }
            try w.writeByte('e');
        },
    }
}

/// Convenience: look up `key` in a dict-decoded value. Returns null
/// when `v` is not a dict or `key` is absent.
pub fn dictGet(v: Decoded, key: []const u8) ?Decoded {
    if (v != .dict) return null;
    for (v.dict) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

// --- tests ---

const testing = std.testing;

test "decode/encode round-trip — int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try decode(arena.allocator(), "i42e");
    try testing.expectEqual(@as(i64, 42), r.value.int);
    try testing.expectEqual(@as(usize, 4), r.consumed);
    const back = try encode(testing.allocator, r.value);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("i42e", back);
}

test "decode/encode round-trip — negative int" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try decode(arena.allocator(), "i-7e");
    try testing.expectEqual(@as(i64, -7), r.value.int);
}

test "decode/encode round-trip — string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try decode(arena.allocator(), "5:hello");
    try testing.expectEqualStrings("hello", r.value.str);
    const back = try encode(testing.allocator, r.value);
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("5:hello", back);
}

test "decode/encode round-trip — list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try decode(arena.allocator(), "li1e3:fooi2ee");
    try testing.expect(r.value == .list);
    try testing.expectEqual(@as(usize, 3), r.value.list.len);
    try testing.expectEqual(@as(i64, 1), r.value.list[0].int);
    try testing.expectEqualStrings("foo", r.value.list[1].str);
    try testing.expectEqual(@as(i64, 2), r.value.list[2].int);
}

test "decode/encode round-trip — dict + dictGet + sort" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try decode(arena.allocator(), "d3:bari1e3:foo5:helloe");
    try testing.expect(r.value == .dict);
    const bar = dictGet(r.value, "bar").?;
    try testing.expectEqual(@as(i64, 1), bar.int);
    const foo = dictGet(r.value, "foo").?;
    try testing.expectEqualStrings("hello", foo.str);
    try testing.expect(dictGet(r.value, "absent") == null);

    // Encode preserves sort even if input is unsorted.
    const entries = [_]Decoded.Entry{
        .{ .key = "foo", .value = .{ .int = 1 } },
        .{ .key = "bar", .value = .{ .int = 2 } },
    };
    const back = try encode(testing.allocator, .{ .dict = &entries });
    defer testing.allocator.free(back);
    try testing.expectEqualStrings("d3:bari2e3:fooi1ee", back);
}

test "decode rejects truncated input cleanly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedEof, decode(arena.allocator(), "i42"));
    try testing.expectError(error.UnexpectedEof, decode(arena.allocator(), "5:hel"));
    try testing.expectError(error.UnexpectedEof, decode(arena.allocator(), "li1"));
    try testing.expectError(error.InvalidPrefix, decode(arena.allocator(), "x"));
}
