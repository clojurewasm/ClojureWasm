// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.util.UUID — UUID generation and parsing.
//!
//! Static methods: UUID/randomUUID, UUID/fromString
//! Instance methods: .toString, .getMostSignificantBits, .getLeastSignificantBits
//! Constructor: (UUID. msb lsb) — two longs

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.util.UUID";

/// Construct a UUID from its string representation.
pub fn constructFromString(allocator: Allocator, uuid_str: []const u8) anyerror!Value {
    // Validate UUID format: 8-4-4-4-12 (36 chars)
    if (uuid_str.len != 36) return err.setErrorFmt(.eval, .value_error, .{}, "Invalid UUID string: {s}", .{uuid_str});
    if (uuid_str[8] != '-' or uuid_str[13] != '-' or uuid_str[18] != '-' or uuid_str[23] != '-')
        return err.setErrorFmt(.eval, .value_error, .{}, "Invalid UUID string: {s}", .{uuid_str});

    // Store as string value
    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "uuid" });
    extra[1] = Value.initString(allocator, try allocator.dupe(u8, uuid_str));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Construct a UUID from two longs (msb, lsb).
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 1 and args[0].tag() == .string) {
        return constructFromString(allocator, args[0].asString());
    }
    if (args.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, "UUID constructor expects 2 long args or 1 string arg, got {d}", .{args.len});

    const msb = args[0].asInteger();
    const lsb = args[1].asInteger();

    const uuid_str = try std.fmt.allocPrint(allocator, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
        @as(u32, @truncate(@as(u64, @bitCast(msb)) >> 32)),
        @as(u16, @truncate(@as(u64, @bitCast(msb)) >> 16)),
        @as(u16, @truncate(@as(u64, @bitCast(msb)))),
        @as(u16, @truncate(@as(u64, @bitCast(lsb)) >> 48)),
        @as(u48, @truncate(@as(u64, @bitCast(lsb)))),
    });

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "uuid" });
    extra[1] = Value.initString(allocator, uuid_str);

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Generate a random UUID v4 and return as a UUID class instance.
pub fn randomUUID(allocator: Allocator) anyerror!Value {
    // Generate 16 random bytes
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);

    // Set version 4: byte[6] = (byte[6] & 0x0f) | 0x40
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant 10: byte[8] = (byte[8] & 0x3f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    // Format as UUID string
    const hex_chars = "0123456789abcdef";
    var buf: [36]u8 = undefined;
    var pos: usize = 0;
    for (bytes, 0..) |b, i| {
        buf[pos] = hex_chars[b >> 4];
        pos += 1;
        buf[pos] = hex_chars[b & 0x0f];
        pos += 1;
        if (i == 3 or i == 5 or i == 7 or i == 9) {
            buf[pos] = '-';
            pos += 1;
        }
    }

    return constructFromString(allocator, &buf);
}

/// Dispatch instance method on a UUID object.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    _ = rest;
    const map = obj.asMap();
    const uuid_str = getField(map, "uuid").asString();

    if (std.mem.eql(u8, method, "toString")) {
        return Value.initString(allocator, uuid_str);
    } else if (std.mem.eql(u8, method, "getMostSignificantBits")) {
        return getMsb(uuid_str);
    } else if (std.mem.eql(u8, method, "getLeastSignificantBits")) {
        return getLsb(uuid_str);
    } else if (std.mem.eql(u8, method, "version")) {
        return Value.initInteger(@intCast((uuid_str[14] - '0')));
    } else if (std.mem.eql(u8, method, "variant")) {
        // UUID variant from bits 62-63 of lsb
        const ch = uuid_str[19];
        const nibble = if (ch >= 'a') ch - 'a' + 10 else ch - '0';
        if (nibble & 0x8 == 0) return Value.initInteger(0);
        if (nibble & 0xC == 0x8) return Value.initInteger(2);
        return Value.initInteger(2);
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for java.util.UUID", .{method});
}

fn getMsb(uuid_str: []const u8) Value {
    // Parse first 16 hex chars (skip dashes at positions 8, 13)
    var result: u64 = 0;
    var hex_count: usize = 0;
    for (uuid_str) |ch| {
        if (ch == '-') continue;
        if (hex_count >= 16) break;
        const nibble: u64 = if (ch >= 'a') ch - 'a' + 10 else if (ch >= 'A') ch - 'A' + 10 else ch - '0';
        result = (result << 4) | nibble;
        hex_count += 1;
    }
    return Value.initInteger(@bitCast(result));
}

fn getLsb(uuid_str: []const u8) Value {
    // Parse last 16 hex chars
    var result: u64 = 0;
    var hex_count: usize = 0;
    var total_hex: usize = 0;
    for (uuid_str) |ch| {
        if (ch == '-') continue;
        total_hex += 1;
        if (total_hex <= 16) continue; // Skip msb
        const nibble: u64 = if (ch >= 'a') ch - 'a' + 10 else if (ch >= 'A') ch - 'A' + 10 else ch - '0';
        result = (result << 4) | nibble;
        hex_count += 1;
    }
    return Value.initInteger(@bitCast(result));
}

/// Helper: get a keyword field from a PersistentArrayMap by name.
fn getField(map: *const value_mod.PersistentArrayMap, name: []const u8) Value {
    var i: usize = 0;
    while (i + 1 < map.entries.len) : (i += 2) {
        if (map.entries[i].tag() == .keyword) {
            const kw = map.entries[i].asKeyword();
            if (kw.ns == null and std.mem.eql(u8, kw.name, name)) {
                return map.entries[i + 1];
            }
        }
    }
    return Value.nil_val;
}

// Tests
const testing = std.testing;

test "UUID constructFromString — valid" {
    const allocator = std.heap.page_allocator;
    const result = try constructFromString(allocator, "550e8400-e29b-41d4-a716-446655440000");
    try testing.expect(result.tag() == .map);
}

test "UUID randomUUID — format" {
    const allocator = std.heap.page_allocator;
    const result = try randomUUID(allocator);
    try testing.expect(result.tag() == .map);
}
