// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.io.BufferedWriter — file-backed writer with buffered output.
//!
//! UPSTREAM-DIFF: Buffers all content in memory and writes to file on .flush() or .close().
//! Not a true streaming writer, but API-compatible for typical use patterns.
//!
//! Constructor: Internal only (created by clojure.java.io/writer)
//! Instance methods: .write(String), .newLine(), .flush(), .close(), .toString()
//!
//! Mutable state uses smp_allocator to avoid GC tracing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.io.BufferedWriter";

/// Mutable state for BufferedWriter.
const State = struct {
    buf: std.ArrayList(u8),
    path: []const u8,
    append_mode: bool,
    closed: bool,

    fn init(path: []const u8, append_mode: bool) State {
        return .{
            .buf = std.ArrayList(u8).empty,
            .path = path,
            .append_mode = append_mode,
            .closed = false,
        };
    }

    fn writeStr(self: *State, s: []const u8) !void {
        if (self.closed) return error.Closed;
        self.buf.appendSlice(std.heap.smp_allocator, s) catch return error.OutOfMemory;
    }

    fn flush(self: *State) !void {
        if (self.closed) return error.Closed;
        const file = if (self.append_mode)
            std.fs.cwd().openFile(self.path, .{ .mode = .write_only }) catch
                std.fs.cwd().createFile(self.path, .{}) catch return error.FileNotFound
        else
            std.fs.cwd().createFile(self.path, .{}) catch return error.FileNotFound;
        defer file.close();
        if (self.append_mode) file.seekFromEnd(0) catch {};
        file.writeAll(self.buf.items) catch return error.FileNotFound;
        self.buf.clearRetainingCapacity();
    }

    fn close(self: *State) !void {
        if (self.closed) return;
        self.flush() catch {};
        self.closed = true;
    }

    fn toString(self: *const State) []const u8 {
        return self.buf.items;
    }
};

/// Construct a BufferedWriter for a file path.
/// Internal constructor (called from Clojure io/writer).
/// args: [path-string] or [path-string append-bool]
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1 or args.len > 2)
        return err.setErrorFmt(.eval, .arity_error, .{}, "BufferedWriter expects 1-2 args, got {d}", .{args.len});
    if (args[0].tag() != .string)
        return err.setErrorFmt(.eval, .type_error, .{}, "BufferedWriter expects string path", .{});

    const path = args[0].asString();
    const append_mode = if (args.len > 1) args[1].isTruthy() else false;

    // Dupe path to smp_allocator for state ownership
    const owned_path = std.heap.smp_allocator.dupe(u8, path) catch return error.OutOfMemory;

    const state = std.heap.smp_allocator.create(State) catch return error.OutOfMemory;
    state.* = State.init(owned_path, append_mode);

    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__handle" });
    extra[1] = Value.initInteger(@intCast(@intFromPtr(state)));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Get mutable state from a BufferedWriter instance map.
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

/// Dispatch instance method on a BufferedWriter.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    const state = getState(obj) orelse
        return err.setErrorFmt(.eval, .value_error, .{}, "Invalid BufferedWriter instance", .{});

    if (std.mem.eql(u8, method, "write")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".write expects 1 arg", .{});
        if (rest[0].tag() == .string) {
            state.writeStr(rest[0].asString()) catch
                return err.setErrorFmt(.eval, .io_error, .{}, "Writer is closed", .{});
        } else if (rest[0].tag() == .integer) {
            const cp: u21 = @intCast(@as(u64, @bitCast(rest[0].asInteger())) & 0x1FFFFF);
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &buf) catch return error.ValueError;
            state.writeStr(buf[0..len]) catch
                return err.setErrorFmt(.eval, .io_error, .{}, "Writer is closed", .{});
        } else if (rest[0].tag() == .char) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(rest[0].asChar(), &buf) catch return error.ValueError;
            state.writeStr(buf[0..len]) catch
                return err.setErrorFmt(.eval, .io_error, .{}, "Writer is closed", .{});
        } else {
            return err.setErrorFmt(.eval, .type_error, .{}, ".write: unsupported type {s}", .{@tagName(rest[0].tag())});
        }
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "newLine")) {
        state.writeStr("\n") catch
            return err.setErrorFmt(.eval, .io_error, .{}, "Writer is closed", .{});
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "flush")) {
        state.flush() catch
            return err.setErrorFmt(.eval, .io_error, .{}, "Failed to flush writer", .{});
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "close")) {
        state.close() catch {};
        return Value.nil_val;
    }

    if (std.mem.eql(u8, method, "toString")) {
        return Value.initString(allocator, state.toString());
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for BufferedWriter", .{method});
}

// Tests
const testing = std.testing;

test "BufferedWriter State — write and toString" {
    var state = State.init("/dev/null", false);
    try state.writeStr("hello");
    try state.writeStr(" world");
    try testing.expectEqualStrings("hello world", state.toString());
}
