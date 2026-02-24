// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.io.StringWriter — in-memory Writer that accumulates to a string.
//!
//! Constructor: (StringWriter.)
//! Instance methods: .write(int), .write(String), .append(CharSequence), .toString, .close()
//! Also responds to (str writer) via toString dispatch.
//!
//! Mutable state uses smp_allocator to avoid GC tracing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.io.StringWriter";

/// Mutable state for StringWriter (same structure as StringBuilder).
const State = struct {
    buf: std.ArrayList(u8),
    closed: bool = false,

    fn init() State {
        return .{ .buf = std.ArrayList(u8).empty };
    }

    fn deinit(self: *State) void {
        self.buf.deinit(std.heap.smp_allocator);
        self.closed = true;
    }

    fn writeChar(self: *State, c: u8) !void {
        self.buf.append(std.heap.smp_allocator, c) catch return error.OutOfMemory;
    }

    fn writeStr(self: *State, s: []const u8) !void {
        self.buf.appendSlice(std.heap.smp_allocator, s) catch return error.OutOfMemory;
    }

    fn toString(self: *const State) []const u8 {
        return self.buf.items;
    }
};

/// Construct a StringWriter.
/// (StringWriter.) — empty
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "StringWriter expects 0 args, got {d}", .{args.len});

    const state = std.heap.smp_allocator.create(State) catch return error.OutOfMemory;
    state.* = State.init();

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__handle" });
    extra[1] = Value.initInteger(@intCast(@intFromPtr(state)));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Get mutable state from a StringWriter instance map.
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

/// Dispatch instance method on a StringWriter.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    const state = getState(obj) orelse
        return err.setErrorFmt(.eval, .value_error, .{}, "Invalid StringWriter instance", .{});

    // .close() — release resources
    if (std.mem.eql(u8, method, "close")) {
        if (!state.closed) state.deinit();
        return Value.nil_val;
    }

    // Check closed state for all other operations
    if (state.closed)
        return err.setErrorFmt(.eval, .value_error, .{}, "StringWriter is closed", .{});

    if (std.mem.eql(u8, method, "write")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".write expects 1 arg", .{});
        if (rest[0].tag() == .integer) {
            // .write(int) — write single character by code point
            const cp: u21 = @intCast(@as(u64, @bitCast(rest[0].asInteger())) & 0x1FFFFF);
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.ValueError;
            state.writeStr(buf[0..len]) catch return error.OutOfMemory;
        } else if (rest[0].tag() == .string) {
            state.writeStr(rest[0].asString()) catch return error.OutOfMemory;
        } else if (rest[0].tag() == .char) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(rest[0].asChar(), &buf) catch return error.ValueError;
            state.writeStr(buf[0..len]) catch return error.OutOfMemory;
        } else {
            return err.setErrorFmt(.eval, .type_error, .{}, ".write: unsupported type {s}", .{@tagName(rest[0].tag())});
        }
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "append")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".append expects 1 arg", .{});
        if (rest[0].tag() == .string) {
            state.writeStr(rest[0].asString()) catch return error.OutOfMemory;
        } else if (rest[0].tag() == .char) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(rest[0].asChar(), &buf) catch return error.ValueError;
            state.writeStr(buf[0..len]) catch return error.OutOfMemory;
        } else {
            return err.setErrorFmt(.eval, .type_error, .{}, ".append: unsupported type {s}", .{@tagName(rest[0].tag())});
        }
        return obj; // append returns this
    }

    if (std.mem.eql(u8, method, "toString")) {
        const s = state.toString();
        return Value.initString(allocator, try allocator.dupe(u8, s));
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for StringWriter", .{method});
}

// Tests
const testing = std.testing;

test "StringWriter State — write and toString" {
    var state = State.init();
    defer state.deinit();

    try state.writeChar('h');
    try state.writeStr("ello");
    try testing.expectEqualStrings("hello", state.toString());
}
