// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.lang.StringBuilder — mutable string accumulator.
//!
//! Constructor: (StringBuilder.) or (StringBuilder. "init")
//! Instance methods: .append(char/string), .toString, .length
//! Also responds to (str builder) via toString dispatch.
//!
//! Mutable state is stored in a Zig-allocated ArrayList referenced by an
//! opaque handle (integer pointer). Uses smp_allocator to avoid GC tracing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.lang.StringBuilder";

/// Mutable state for StringBuilder.
const State = struct {
    buf: std.ArrayList(u8),
    closed: bool = false,

    fn init() State {
        return .{ .buf = std.ArrayList(u8).empty };
    }

    fn initWithString(s: []const u8) !State {
        var buf: std.ArrayList(u8) = .empty;
        buf.appendSlice(std.heap.smp_allocator, s) catch return error.OutOfMemory;
        return .{ .buf = buf };
    }

    fn deinit(self: *State) void {
        self.buf.deinit(std.heap.smp_allocator);
        self.closed = true;
    }

    fn appendChar(self: *State, c: u8) !void {
        self.buf.append(std.heap.smp_allocator, c) catch return error.OutOfMemory;
    }

    fn appendStr(self: *State, s: []const u8) !void {
        self.buf.appendSlice(std.heap.smp_allocator, s) catch return error.OutOfMemory;
    }

    fn toString(self: *const State) []const u8 {
        return self.buf.items;
    }

    fn length(self: *const State) usize {
        return self.buf.items.len;
    }
};

/// Construct a StringBuilder.
/// (StringBuilder.) — empty
/// (StringBuilder. "initial") — pre-populated
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    const state = std.heap.smp_allocator.create(State) catch return error.OutOfMemory;
    if (args.len == 0) {
        state.* = State.init();
    } else if (args.len == 1 and args[0].tag() == .string) {
        state.* = State.initWithString(args[0].asString()) catch return error.OutOfMemory;
    } else {
        std.heap.smp_allocator.destroy(state);
        return err.setErrorFmt(.eval, .arity_error, .{}, "StringBuilder expects 0 or 1 string arg, got {d}", .{args.len});
    }

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__handle" });
    extra[1] = Value.initInteger(@as(i64, @bitCast(@intFromPtr(state))));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Get mutable state from a StringBuilder instance map.
fn getState(obj: Value) ?*State {
    if (obj.tag() != .map) return null;
    const entries = obj.asMap().entries;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].tag() == .keyword) {
            const kw = entries[i].asKeyword();
            if (kw.ns == null and std.mem.eql(u8, kw.name, "__handle")) {
                if (entries[i + 1].tag() == .integer) {
                    const ptr_int: usize = @bitCast(entries[i + 1].asInteger());
                    return @ptrFromInt(ptr_int);
                }
            }
        }
    }
    return null;
}

/// Dispatch instance method on a StringBuilder.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    const state = getState(obj) orelse
        return err.setErrorFmt(.eval, .value_error, .{}, "Invalid StringBuilder instance", .{});

    // .close() — release resources
    if (std.mem.eql(u8, method, "close")) {
        if (!state.closed) state.deinit();
        return Value.nil_val;
    }

    // Check closed state for all other operations
    if (state.closed)
        return err.setErrorFmt(.eval, .value_error, .{}, "StringBuilder is closed", .{});

    if (std.mem.eql(u8, method, "append")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".append expects 1 arg", .{});
        if (rest[0].tag() == .char) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(rest[0].asChar(), &buf) catch return error.ValueError;
            state.appendStr(buf[0..len]) catch return error.OutOfMemory;
        } else if (rest[0].tag() == .string) {
            state.appendStr(rest[0].asString()) catch return error.OutOfMemory;
        } else if (rest[0].tag() == .integer) {
            // .append(int) — append character by code point
            const cp: u21 = @intCast(rest[0].asInteger());
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.ValueError;
            state.appendStr(buf[0..len]) catch return error.OutOfMemory;
        } else {
            return err.setErrorFmt(.eval, .type_error, .{}, ".append: unsupported type {s}", .{@tagName(rest[0].tag())});
        }
        return obj; // StringBuilder.append returns this
    }

    if (std.mem.eql(u8, method, "toString")) {
        const s = state.toString();
        return Value.initString(allocator, try allocator.dupe(u8, s));
    }

    if (std.mem.eql(u8, method, "length")) {
        return Value.initInteger(@intCast(state.length()));
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for StringBuilder", .{method});
}

// Tests
const testing = std.testing;

test "StringBuilder — construct empty and append" {
    const state = std.heap.smp_allocator.create(State) catch unreachable;
    state.* = State.init();
    defer std.heap.smp_allocator.destroy(state);
    defer state.deinit();

    try state.appendChar('h');
    try state.appendStr("ello");
    try testing.expectEqualStrings("hello", state.toString());
    try testing.expectEqual(@as(usize, 5), state.length());
}

test "StringBuilder — construct with initial string" {
    const state = std.heap.smp_allocator.create(State) catch unreachable;
    state.* = try State.initWithString("hello");
    defer std.heap.smp_allocator.destroy(state);
    defer state.deinit();

    try state.appendStr(" world");
    try testing.expectEqualStrings("hello world", state.toString());
}
