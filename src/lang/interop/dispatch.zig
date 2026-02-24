// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Java instance method dispatch — __java-method implementation.
//!
//! Extracted from strings.zig. Dispatches (.method obj args...) calls
//! by checking the object's tag first, then :__reify_type on maps
//! for class instances.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../runtime/error.zig");
const collections = @import("../builtins/collections.zig");
const class_registry = @import("class_registry.zig");

/// Java instance method dispatch.
/// Called from __java-method builtin. Dispatches based on object tag,
/// then falls back to :__reify_type metadata check for class instances.
pub fn dispatch(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    // String methods
    if (obj.tag() == .string) {
        return dispatchString(allocator, method, obj.asString(), rest);
    }

    // Char methods (Java Character)
    if (obj.tag() == .char) {
        if (std.mem.eql(u8, method, "toString") or std.mem.eql(u8, method, "valueOf")) {
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(obj.asChar(), &buf) catch return error.ValueError;
            return Value.initString(allocator, try allocator.dupe(u8, buf[0..len]));
        }
    }

    // Check :__reify_type on maps for class instances (before generic collection methods)
    if (obj.tag() == .map or obj.tag() == .hash_map) {
        if (getReifyType(obj)) |rt| {
            return dispatchClass(allocator, rt, method, obj, rest);
        }
        // Exception maps: maps with :__ex_info key (no __reify_type)
        if (isExceptionMap(obj)) {
            return dispatchException(allocator, method, obj);
        }
    }

    // Collection methods (only for non-class-instance collections)
    if (std.mem.eql(u8, method, "size") or std.mem.eql(u8, method, "length")) {
        return collections.countFn(allocator, &.{obj});
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} found for {s}", .{ method, @tagName(obj.tag()) });
}

/// Dispatch instance method on a class instance identified by :__reify_type.
/// Uses ClassDef registry for extensible dispatch.
fn dispatchClass(allocator: Allocator, class_name: []const u8, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    if (class_registry.dispatchMethod(allocator, class_name, method, obj, rest)) |result| {
        return result;
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for class {s}", .{ method, class_name });
}

/// Extract :__reify_type value from a map by scanning entries directly.
/// Zero-allocation: iterates map entries looking for :__reify_type keyword key.
pub fn getReifyType(obj: Value) ?[]const u8 {
    if (obj.tag() == .map) {
        const entries = obj.asMap().entries;
        var i: usize = 0;
        while (i + 1 < entries.len) : (i += 2) {
            if (collections.isReifyTypeKey(entries[i])) {
                if (entries[i + 1].tag() == .string) return entries[i + 1].asString();
            }
        }
    }
    // hash_map: use get() with keyword
    // For now, class instances are always small maps (PersistentArrayMap)
    return null;
}

/// Check if a map is an exception map (has :__ex_info key).
fn isExceptionMap(obj: Value) bool {
    if (obj.tag() == .map) {
        const entries = obj.asMap().entries;
        var i: usize = 0;
        while (i + 1 < entries.len) : (i += 2) {
            if (entries[i].tag() == .keyword) {
                const kw = entries[i].asKeyword();
                if (kw.ns == null and std.mem.eql(u8, kw.name, "__ex_info")) return true;
            }
        }
    }
    return false;
}

/// Get a keyword value from a map by scanning entries.
fn getMapKeywordValue(obj: Value, key_name: []const u8) ?Value {
    if (obj.tag() == .map) {
        const entries = obj.asMap().entries;
        var i: usize = 0;
        while (i + 1 < entries.len) : (i += 2) {
            if (entries[i].tag() == .keyword) {
                const kw = entries[i].asKeyword();
                if (kw.ns == null and std.mem.eql(u8, kw.name, key_name)) return entries[i + 1];
            }
        }
    }
    return null;
}

/// Dispatch instance methods on exception maps.
/// Supports: .getMessage, .getCause, .getData, .toString, .getLocalizedMessage
fn dispatchException(allocator: Allocator, method: []const u8, obj: Value) anyerror!Value {
    if (std.mem.eql(u8, method, "getMessage") or std.mem.eql(u8, method, "getLocalizedMessage")) {
        const msg = getMapKeywordValue(obj, "message") orelse return Value.nil_val;
        return msg;
    } else if (std.mem.eql(u8, method, "getCause")) {
        return getMapKeywordValue(obj, "cause") orelse Value.nil_val;
    } else if (std.mem.eql(u8, method, "getData")) {
        return getMapKeywordValue(obj, "data") orelse Value.nil_val;
    } else if (std.mem.eql(u8, method, "toString")) {
        // Format: "ExType: message" (like Java)
        const ex_type = getMapKeywordValue(obj, "__ex_type");
        const msg = getMapKeywordValue(obj, "message");
        const type_str = if (ex_type) |et| (if (et.tag() == .string) et.asString() else "Exception") else "Exception";
        const msg_str = if (msg) |m| (if (m.tag() == .string) m.asString() else "") else "";
        if (msg_str.len > 0) {
            const buf = try std.fmt.allocPrint(allocator, "{s}: {s}", .{ type_str, msg_str });
            return Value.initString(allocator, buf);
        }
        return Value.initString(allocator, try allocator.dupe(u8, type_str));
    }
    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} found for exception", .{method});
}

// String method dispatch — extracted from strings.zig
const cp = @import("../../runtime/codepoint.zig");

fn dispatchString(allocator: Allocator, method: []const u8, s: []const u8, rest: []const Value) anyerror!Value {
    if (std.mem.eql(u8, method, "length")) {
        return Value.initInteger(@intCast(cp.codepointCount(s)));
    } else if (std.mem.eql(u8, method, "substring")) {
        if (rest.len == 1) {
            const begin: usize = @intCast(rest[0].asInteger());
            const slice = cp.codepointSliceFrom(s, begin) orelse
                return err.setErrorFmt(.eval, .value_error, .{}, "String index out of range: {d}", .{begin});
            return Value.initString(allocator, try allocator.dupe(u8, slice));
        } else if (rest.len == 2) {
            const begin: usize = @intCast(rest[0].asInteger());
            const end: usize = @intCast(rest[1].asInteger());
            const slice = cp.codepointSlice(s, begin, end) orelse
                return err.setErrorFmt(.eval, .value_error, .{}, "String index out of range", .{});
            return Value.initString(allocator, try allocator.dupe(u8, slice));
        }
        return err.setErrorFmt(.eval, .arity_error, .{}, ".substring expects 1 or 2 args", .{});
    } else if (std.mem.eql(u8, method, "charAt")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".charAt expects 1 arg", .{});
        const idx: usize = @intCast(rest[0].asInteger());
        const codepoint_val = cp.codepointAt(s, idx) orelse
            return err.setErrorFmt(.eval, .value_error, .{}, "String index out of range: {d}", .{idx});
        return Value.initChar(codepoint_val);
    } else if (std.mem.eql(u8, method, "indexOf")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".indexOf expects 1 arg", .{});
        const needle = rest[0].asString();
        return Value.initInteger(cp.codepointIndexOf(s, needle));
    } else if (std.mem.eql(u8, method, "contains")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".contains expects 1 arg", .{});
        const needle = rest[0].asString();
        return Value.initBoolean(std.mem.indexOf(u8, s, needle) != null);
    } else if (std.mem.eql(u8, method, "startsWith")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".startsWith expects 1 arg", .{});
        const prefix = rest[0].asString();
        return Value.initBoolean(std.mem.startsWith(u8, s, prefix));
    } else if (std.mem.eql(u8, method, "endsWith")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".endsWith expects 1 arg", .{});
        const suffix = rest[0].asString();
        return Value.initBoolean(std.mem.endsWith(u8, s, suffix));
    } else if (std.mem.eql(u8, method, "toUpperCase")) {
        const buf = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
        return Value.initString(allocator, buf);
    } else if (std.mem.eql(u8, method, "toLowerCase")) {
        const buf = try allocator.alloc(u8, s.len);
        for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
        return Value.initString(allocator, buf);
    } else if (std.mem.eql(u8, method, "trim")) {
        const trimmed = std.mem.trim(u8, s, " \t\n\r");
        return Value.initString(allocator, try allocator.dupe(u8, trimmed));
    } else if (std.mem.eql(u8, method, "replace")) {
        if (rest.len != 2) return err.setErrorFmt(.eval, .arity_error, .{}, ".replace expects 2 args", .{});
        const target = rest[0].asString();
        const replacement = rest[1].asString();
        const result = try std.mem.replaceOwned(u8, allocator, s, target, replacement);
        return Value.initString(allocator, result);
    } else if (std.mem.eql(u8, method, "isEmpty")) {
        return Value.initBoolean(s.len == 0);
    } else if (std.mem.eql(u8, method, "equals")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".equals expects 1 arg", .{});
        if (rest[0].tag() != .string) return Value.false_val;
        return Value.initBoolean(std.mem.eql(u8, s, rest[0].asString()));
    } else if (std.mem.eql(u8, method, "toString") or std.mem.eql(u8, method, "valueOf")) {
        return Value.initString(allocator, s);
    } else if (std.mem.eql(u8, method, "compareTo")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".compareTo expects 1 arg", .{});
        const other = rest[0].asString();
        const result = std.mem.order(u8, s, other);
        return Value.initInteger(switch (result) { .lt => -1, .eq => 0, .gt => 1 });
    } else if (std.mem.eql(u8, method, "concat")) {
        if (rest.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, ".concat expects 1 arg", .{});
        const other = rest[0].asString();
        const buf = try allocator.alloc(u8, s.len + other.len);
        @memcpy(buf[0..s.len], s);
        @memcpy(buf[s.len..], other);
        return Value.initString(allocator, buf);
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} found for string", .{method});
}

// Tests
const testing = std.testing;

test "dispatchException — getMessage" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const msg = Value.initString(alloc, try alloc.dupe(u8, "boom"));
    const ex = try constructors.makeExceptionMap(alloc, "Exception", &.{msg});
    const result = try dispatchException(alloc, "getMessage", ex);
    try testing.expectEqualStrings("boom", result.asString());
}

test "dispatchException — getCause" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const ex = try constructors.makeExceptionMap(alloc, "RuntimeException", &.{});
    const result = try dispatchException(alloc, "getCause", ex);
    try testing.expect(result.isNil());
}

test "dispatchException — toString" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const msg = Value.initString(alloc, try alloc.dupe(u8, "/ by zero"));
    const ex = try constructors.makeExceptionMap(alloc, "ArithmeticException", &.{msg});
    const result = try dispatchException(alloc, "toString", ex);
    try testing.expectEqualStrings("ArithmeticException: / by zero", result.asString());
}

test "dispatchException — unknown method errors" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const ex = try constructors.makeExceptionMap(alloc, "Exception", &.{});
    const result = dispatchException(alloc, "nonexistent", ex);
    try testing.expectError(error.ValueError, result);
}

test "isExceptionMap" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const msg = Value.initString(alloc, try alloc.dupe(u8, "test"));
    const ex = try constructors.makeExceptionMap(alloc, "Exception", &.{msg});
    try testing.expect(isExceptionMap(ex));
    try testing.expect(!isExceptionMap(Value.nil_val));
}

test "dispatch — .getMessage on exception map" {
    const alloc = std.heap.page_allocator;
    const constructors = @import("constructors.zig");
    const msg = Value.initString(alloc, try alloc.dupe(u8, "hello"));
    const ex = try constructors.makeExceptionMap(alloc, "Exception", &.{msg});
    const result = try dispatch(alloc, "getMessage", ex, &.{});
    try testing.expectEqualStrings("hello", result.asString());
}
