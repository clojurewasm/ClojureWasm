// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.io.PushbackReader — character reader with pushback support.
//!
//! Constructor: (PushbackReader. reader) or (PushbackReader. reader bufsize)
//! Instance methods: .read() -> int, .unread(int), .close()
//!
//! Also provides StringReader support:
//! Constructor: (StringReader. "text")
//! Used as: (PushbackReader. (StringReader. "text"))
//!
//! Mutable state uses smp_allocator to avoid GC tracing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../runtime/error.zig");
const constructors = @import("../constructors.zig");
const interop_dispatch = @import("../dispatch.zig");

pub const class_name = "java.io.PushbackReader";
pub const string_reader_class_name = "java.io.StringReader";

/// Mutable state for PushbackReader.
const State = struct {
    source: []const u8,
    pos: usize,
    pushback_buf: [64]u8,
    pushback_len: usize,
    closed: bool = false,

    fn init(source: []const u8) State {
        return .{
            .source = source,
            .pos = 0,
            .pushback_buf = undefined,
            .pushback_len = 0,
        };
    }

    /// Read a single character. Returns -1 on EOF.
    fn read(self: *State) i64 {
        // Check pushback buffer first (LIFO)
        if (self.pushback_len > 0) {
            self.pushback_len -= 1;
            return @intCast(self.pushback_buf[self.pushback_len]);
        }
        // Read from source
        if (self.pos >= self.source.len) return -1;
        const c = self.source[self.pos];
        self.pos += 1;
        return @intCast(c);
    }

    /// Push back a single character.
    fn unread(self: *State, c: u8) !void {
        if (self.pushback_len >= self.pushback_buf.len) {
            return error.OutOfMemory; // Pushback buffer overflow
        }
        self.pushback_buf[self.pushback_len] = c;
        self.pushback_len += 1;
    }
};

/// Construct a StringReader from a string.
/// (StringReader. "text")
pub fn constructStringReader(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "StringReader expects 1 string arg, got {d}", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "StringReader expects a string arg", .{});

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "source" });
    extra[1] = args[0]; // Keep reference to source string

    return constructors.makeClassInstance(allocator, string_reader_class_name, extra);
}

/// Extract source string from a StringReader instance.
fn getStringReaderSource(obj: Value) ?[]const u8 {
    if (obj.tag() != .map) return null;
    const entries = obj.asMap().entries;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].tag() == .keyword) {
            const kw = entries[i].asKeyword();
            if (kw.ns == null and std.mem.eql(u8, kw.name, "source")) {
                if (entries[i + 1].tag() == .string) return entries[i + 1].asString();
            }
        }
    }
    return null;
}

/// Construct a PushbackReader.
/// (PushbackReader. reader) or (PushbackReader. reader bufsize)
/// reader must be a StringReader or a string.
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2)
        return err.setErrorFmt(.eval, .arity_error, .{}, "PushbackReader expects 1-2 args, got {d}", .{args.len});

    // Extract source string from the reader argument
    const source: []const u8 = blk: {
        const reader_arg = args[0];
        // Direct string (convenience)
        if (reader_arg.tag() == .string) break :blk reader_arg.asString();
        // StringReader instance
        if (reader_arg.tag() == .map) {
            if (interop_dispatch.getReifyType(reader_arg)) |rt| {
                if (std.mem.eql(u8, rt, string_reader_class_name)) {
                    if (getStringReaderSource(reader_arg)) |s| break :blk s;
                }
            }
        }
        return err.setErrorFmt(.eval, .type_error, .{}, "PushbackReader expects a Reader or string arg", .{});
    };

    const state = std.heap.smp_allocator.create(State) catch return error.OutOfMemory;
    state.* = State.init(source);

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__handle" });
    extra[1] = Value.initInteger(@intCast(@intFromPtr(state)));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Get mutable state from a PushbackReader instance map.
fn getState(obj: Value) ?*State {
    if (obj.tag() != .map) return null;
    const entries = obj.asMap().entries;
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].tag() == .keyword) {
            const kw = entries[i].asKeyword();
            if (kw.ns == null and std.mem.eql(u8, kw.name, "__handle")) {
                if (entries[i + 1].tag() == .integer) {
                    const ptr_int: usize = @intCast(entries[i + 1].asInteger());
                    return @ptrFromInt(ptr_int);
                }
            }
        }
    }
    return null;
}

/// Dispatch instance method on a PushbackReader.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    const state = getState(obj) orelse
        return err.setErrorFmt(.eval, .value_error, .{}, "Invalid PushbackReader instance", .{});

    // .close() — mark as closed and release state
    if (std.mem.eql(u8, method, "close")) {
        state.closed = true;
        return Value.nil_val;
    }

    // Check closed state for all other operations
    if (state.closed)
        return err.setErrorFmt(.eval, .value_error, .{}, "PushbackReader is closed", .{});

    if (std.mem.eql(u8, method, "read")) {
        if (rest.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, ".read expects 0 args", .{});
        return Value.initInteger(state.read());
    }

    if (std.mem.eql(u8, method, "unread")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".unread expects 1 arg", .{});
        const c: u8 = blk: {
            if (rest[0].tag() == .integer) break :blk @intCast(@as(u64, @bitCast(rest[0].asInteger())) & 0xFF);
            if (rest[0].tag() == .char) break :blk @intCast(@as(u32, rest[0].asChar()) & 0xFF);
            return err.setErrorFmt(.eval, .type_error, .{}, ".unread expects int or char arg", .{});
        };
        state.unread(c) catch return err.setErrorFmt(.eval, .value_error, .{}, "Pushback buffer overflow", .{});
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "readLine")) {
        if (rest.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, ".readLine expects 0 args", .{});
        // Read until \n or EOF. Returns nil on EOF (no more data).
        var line = std.ArrayList(u8).empty;
        var saw_any = false;
        while (true) {
            const c = state.read();
            if (c == -1) break;
            saw_any = true;
            if (c == '\n') break;
            if (c == '\r') {
                // Peek next char for \r\n
                const next = state.read();
                if (next != -1 and next != '\n') {
                    state.unread(@intCast(@as(u64, @bitCast(next)) & 0xFF)) catch {};
                }
                break;
            }
            line.append(allocator, @intCast(@as(u64, @bitCast(c)) & 0xFF)) catch return error.OutOfMemory;
        }
        if (!saw_any) return Value.nil_val;
        return Value.initString(allocator, line.items);
    }

    if (std.mem.eql(u8, method, "ready")) {
        if (rest.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, ".ready expects 0 args", .{});
        const has_data = state.pushback_len > 0 or state.pos < state.source.len;
        return if (has_data) Value.true_val else Value.false_val;
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for PushbackReader", .{method});
}

// Tests
const testing = std.testing;

test "PushbackReader State — basic read" {
    var state = State.init("hello");
    try testing.expectEqual(@as(i64, 'h'), state.read());
    try testing.expectEqual(@as(i64, 'e'), state.read());
    try testing.expectEqual(@as(i64, 'l'), state.read());
    try testing.expectEqual(@as(i64, 'l'), state.read());
    try testing.expectEqual(@as(i64, 'o'), state.read());
    try testing.expectEqual(@as(i64, -1), state.read()); // EOF
    try testing.expectEqual(@as(i64, -1), state.read()); // EOF again
}

test "PushbackReader State — unread" {
    var state = State.init("ab");
    try testing.expectEqual(@as(i64, 'a'), state.read());
    try state.unread('a');
    try testing.expectEqual(@as(i64, 'a'), state.read()); // re-read pushed back char
    try testing.expectEqual(@as(i64, 'b'), state.read());
    try testing.expectEqual(@as(i64, -1), state.read());
}

test "PushbackReader State — multiple unread (LIFO)" {
    var state = State.init("cd");
    try testing.expectEqual(@as(i64, 'c'), state.read());
    try testing.expectEqual(@as(i64, 'd'), state.read());
    try state.unread('d');
    try state.unread('c');
    try testing.expectEqual(@as(i64, 'c'), state.read()); // LIFO: c first
    try testing.expectEqual(@as(i64, 'd'), state.read()); // then d
    try testing.expectEqual(@as(i64, -1), state.read()); // EOF
}
