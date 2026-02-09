// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

// Bencode encoder/decoder for nREPL wire protocol.
//
// Format:
// - String:  <len>:<data>  (e.g. "5:hello")
// - Integer: i<num>e       (e.g. "i42e")
// - List:    l<items>e
// - Dict:    d<key><val>...e  (keys are strings)

const std = @import("std");

/// Bencode value — the four types defined by the format.
pub const BencodeValue = union(enum) {
    string: []const u8,
    integer: i64,
    list: []const BencodeValue,
    dict: []const DictEntry,

    pub const DictEntry = struct {
        key: []const u8,
        value: BencodeValue,
    };
};

/// Look up a key in a dict's entries.
pub fn dictGet(entries: []const BencodeValue.DictEntry, key: []const u8) ?BencodeValue {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

/// Look up a string value by key.
pub fn dictGetString(entries: []const BencodeValue.DictEntry, key: []const u8) ?[]const u8 {
    if (dictGet(entries, key)) |val| {
        return switch (val) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

/// Look up an integer value by key.
pub fn dictGetInt(entries: []const BencodeValue.DictEntry, key: []const u8) ?i64 {
    if (dictGet(entries, key)) |val| {
        return switch (val) {
            .integer => |n| n,
            else => null,
        };
    }
    return null;
}

pub const DecodeError = error{
    InvalidFormat,
    UnexpectedEof,
    OutOfMemory,
    Overflow,
};

/// Decode one bencode value from data. Returns value and number of bytes consumed.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!struct { value: BencodeValue, consumed: usize } {
    if (data.len == 0) return error.UnexpectedEof;

    switch (data[0]) {
        // Integer: i<num>e
        'i' => {
            const end = std.mem.indexOfScalar(u8, data, 'e') orelse return error.InvalidFormat;
            if (end <= 1) return error.InvalidFormat;
            const num_str = data[1..end];
            const num = std.fmt.parseInt(i64, num_str, 10) catch return error.InvalidFormat;
            return .{ .value = .{ .integer = num }, .consumed = end + 1 };
        },
        // List: l<items>e
        'l' => {
            var items: std.ArrayList(BencodeValue) = .empty;
            var pos: usize = 1;
            while (pos < data.len and data[pos] != 'e') {
                const result = try decode(allocator, data[pos..]);
                try items.append(allocator, result.value);
                pos += result.consumed;
            }
            if (pos >= data.len) return error.UnexpectedEof;
            return .{
                .value = .{ .list = try items.toOwnedSlice(allocator) },
                .consumed = pos + 1,
            };
        },
        // Dict: d<key><val>...e
        'd' => {
            var entries: std.ArrayList(BencodeValue.DictEntry) = .empty;
            var pos: usize = 1;
            while (pos < data.len and data[pos] != 'e') {
                const key_result = try decode(allocator, data[pos..]);
                const key = switch (key_result.value) {
                    .string => |s| s,
                    else => return error.InvalidFormat,
                };
                pos += key_result.consumed;
                if (pos >= data.len) return error.UnexpectedEof;
                const val_result = try decode(allocator, data[pos..]);
                try entries.append(allocator, .{ .key = key, .value = val_result.value });
                pos += val_result.consumed;
            }
            if (pos >= data.len) return error.UnexpectedEof;
            return .{
                .value = .{ .dict = try entries.toOwnedSlice(allocator) },
                .consumed = pos + 1,
            };
        },
        // String: <len>:<data>
        '0'...'9' => {
            const colon = std.mem.indexOfScalar(u8, data, ':') orelse return error.InvalidFormat;
            const len_str = data[0..colon];
            const len = std.fmt.parseInt(usize, len_str, 10) catch return error.InvalidFormat;
            const start = colon + 1;
            if (start + len > data.len) return error.UnexpectedEof;
            return .{
                .value = .{ .string = data[start .. start + len] },
                .consumed = start + len,
            };
        },
        else => return error.InvalidFormat,
    }
}

/// Encode a bencode value into buf.
pub fn encode(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), val: BencodeValue) !void {
    switch (val) {
        .string => |s| {
            var len_buf: [20]u8 = undefined;
            const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{s.len}) catch unreachable;
            try buf.appendSlice(allocator, len_str);
            try buf.append(allocator, ':');
            try buf.appendSlice(allocator, s);
        },
        .integer => |n| {
            try buf.append(allocator, 'i');
            var num_buf: [20]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{n}) catch unreachable;
            try buf.appendSlice(allocator, num_str);
            try buf.append(allocator, 'e');
        },
        .list => |items| {
            try buf.append(allocator, 'l');
            for (items) |item| {
                try encode(allocator, buf, item);
            }
            try buf.append(allocator, 'e');
        },
        .dict => |entries| {
            try buf.append(allocator, 'd');
            for (entries) |entry| {
                try encode(allocator, buf, .{ .string = entry.key });
                try encode(allocator, buf, entry.value);
            }
            try buf.append(allocator, 'e');
        },
    }
}

/// Convenience: encode a dict and return the byte slice.
pub fn encodeDict(allocator: std.mem.Allocator, entries: []const BencodeValue.DictEntry) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try encode(allocator, &buf, .{ .dict = entries });
    return try buf.toOwnedSlice(allocator);
}

// === Tests ===

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "bencode encode/decode string" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    try encode(allocator, &buf, .{ .string = "hello" });
    try std.testing.expectEqualSlices(u8, "5:hello", buf.items);

    const result = try decode(allocator, buf.items);
    try std.testing.expectEqualSlices(u8, "hello", result.value.string);
    try std.testing.expectEqual(@as(usize, 7), result.consumed);
}

test "bencode encode/decode integer" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    try encode(allocator, &buf, .{ .integer = 42 });
    try std.testing.expectEqualSlices(u8, "i42e", buf.items);

    const result = try decode(allocator, buf.items);
    try std.testing.expectEqual(@as(i64, 42), result.value.integer);
}

test "bencode encode/decode negative integer" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    try encode(allocator, &buf, .{ .integer = -42 });
    try std.testing.expectEqualSlices(u8, "i-42e", buf.items);

    const result = try decode(allocator, buf.items);
    try std.testing.expectEqual(@as(i64, -42), result.value.integer);
}

test "bencode encode/decode list" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    const items = [_]BencodeValue{
        .{ .string = "done" },
        .{ .string = "error" },
    };
    try encode(allocator, &buf, .{ .list = &items });

    const result = try decode(allocator, buf.items);
    const list = result.value.list;
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualSlices(u8, "done", list[0].string);
    try std.testing.expectEqualSlices(u8, "error", list[1].string);
}

test "bencode encode/decode dict" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    const entries = [_]BencodeValue.DictEntry{
        .{ .key = "op", .value = .{ .string = "eval" } },
        .{ .key = "code", .value = .{ .string = "(+ 1 2)" } },
    };
    try encode(allocator, &buf, .{ .dict = &entries });

    const result = try decode(allocator, buf.items);
    const dict = result.value.dict;
    try std.testing.expectEqualSlices(u8, "eval", dictGetString(dict, "op").?);
    try std.testing.expectEqualSlices(u8, "(+ 1 2)", dictGetString(dict, "code").?);
}

test "bencode nested dict roundtrip" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    const status_items = [_]BencodeValue{.{ .string = "done" }};
    const entries = [_]BencodeValue.DictEntry{
        .{ .key = "id", .value = .{ .string = "1" } },
        .{ .key = "status", .value = .{ .list = &status_items } },
        .{ .key = "value", .value = .{ .integer = 3 } },
    };
    try encode(allocator, &buf, .{ .dict = &entries });

    const result = try decode(allocator, buf.items);
    const dict = result.value.dict;
    try std.testing.expectEqualSlices(u8, "1", dictGetString(dict, "id").?);
    try std.testing.expectEqual(@as(i64, 3), dictGetInt(dict, "value").?);
    const status = dictGet(dict, "status").?.list;
    try std.testing.expectEqualSlices(u8, "done", status[0].string);
}

test "bencode empty string" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    var buf: std.ArrayList(u8) = .empty;

    try encode(allocator, &buf, .{ .string = "" });
    try std.testing.expectEqualSlices(u8, "0:", buf.items);

    const result = try decode(allocator, buf.items);
    try std.testing.expectEqualSlices(u8, "", result.value.string);
}

test "bencode consecutive message decode" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const data = "5:helloi42e";

    const r1 = try decode(allocator, data);
    try std.testing.expectEqualSlices(u8, "hello", r1.value.string);

    const r2 = try decode(allocator, data[r1.consumed..]);
    try std.testing.expectEqual(@as(i64, 42), r2.value.integer);
}

test "bencode encodeDict convenience" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]BencodeValue.DictEntry{
        .{ .key = "op", .value = .{ .string = "clone" } },
    };
    const bytes = try encodeDict(allocator, &entries);

    const result = try decode(allocator, bytes);
    try std.testing.expectEqualSlices(u8, "clone", dictGetString(result.value.dict, "op").?);
}
