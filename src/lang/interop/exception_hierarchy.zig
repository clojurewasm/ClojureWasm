// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Exception hierarchy for try/catch dispatch.
//!
//! CW uses a simplified Java exception hierarchy. `(catch ExType e ...)`
//! matches the thrown exception if its `__ex_type` IS or IS-A-SUBCLASS-OF ExType.
//! This table defines the parent-child relationships.

const std = @import("std");

const Entry = struct {
    name: []const u8,
    parent: ?[]const u8,
};

/// Exception class hierarchy (simplified Java model).
/// Only includes exception types that CW actually throws or that users commonly catch.
/// Adding a new exception type = add one entry here.
pub const hierarchy = [_]Entry{
    // Root
    .{ .name = "Throwable", .parent = null },

    // Error branch (serious, usually not caught)
    .{ .name = "Error", .parent = "Throwable" },
    .{ .name = "AssertionError", .parent = "Error" },
    .{ .name = "StackOverflowError", .parent = "Error" },
    .{ .name = "OutOfMemoryError", .parent = "Error" },

    // Exception branch (recoverable)
    .{ .name = "Exception", .parent = "Throwable" },

    // RuntimeException branch (unchecked)
    .{ .name = "RuntimeException", .parent = "Exception" },
    .{ .name = "ArithmeticException", .parent = "RuntimeException" },
    .{ .name = "ArityException", .parent = "RuntimeException" },
    .{ .name = "IllegalArgumentException", .parent = "RuntimeException" },
    .{ .name = "IllegalStateException", .parent = "RuntimeException" },
    .{ .name = "IndexOutOfBoundsException", .parent = "RuntimeException" },
    .{ .name = "NumberFormatException", .parent = "IllegalArgumentException" },
    .{ .name = "UnsupportedOperationException", .parent = "RuntimeException" },
    .{ .name = "ClassCastException", .parent = "RuntimeException" },
    .{ .name = "NullPointerException", .parent = "RuntimeException" },

    // Checked exceptions
    .{ .name = "IOException", .parent = "Exception" },
    .{ .name = "FileNotFoundException", .parent = "IOException" },
    .{ .name = "EOFException", .parent = "IOException" },

    // ExceptionInfo is special: handled separately in catch dispatch.
    // It matches only ex-info exceptions (no __ex_type key).
};

/// Comptime parent lookup table for O(1) access.
const parent_map = blk: {
    var map: [hierarchy.len]struct { name: []const u8, parent: ?[]const u8 } = undefined;
    for (hierarchy, 0..) |entry, i| {
        map[i] = .{ .name = entry.name, .parent = entry.parent };
    }
    break :blk map;
};

/// Get the parent of an exception class. Returns null if root (Throwable) or unknown.
pub fn getParent(class_name: []const u8) ?[]const u8 {
    for (parent_map) |entry| {
        if (std.mem.eql(u8, entry.name, class_name)) return entry.parent;
    }
    return null;
}

/// Check if `child` equals `parent` or is a subclass of `parent`.
/// E.g., isSubclassOf("ArithmeticException", "RuntimeException") = true
///       isSubclassOf("ArithmeticException", "Exception") = true
///       isSubclassOf("ArithmeticException", "IOException") = false
///       isSubclassOf("Exception", "Exception") = true
pub fn isSubclassOf(child: []const u8, parent: []const u8) bool {
    // Exact match
    if (std.mem.eql(u8, child, parent)) return true;

    // Walk up the hierarchy
    var current: ?[]const u8 = child;
    while (current) |c| {
        const p = getParent(c) orelse return false;
        if (std.mem.eql(u8, p, parent)) return true;
        current = p;
    }
    return false;
}

/// Check if a class name is a known exception type in the hierarchy.
pub fn isKnownException(class_name: []const u8) bool {
    for (hierarchy) |entry| {
        if (std.mem.eql(u8, entry.name, class_name)) return true;
    }
    return false;
}

/// Normalize FQCN to simple class name.
/// E.g., "java.lang.Exception" -> "Exception", "java.io.IOException" -> "IOException".
/// Returns the input unchanged if not a known FQCN.
pub fn normalizeClassName(class_name: []const u8) []const u8 {
    const fqcn_map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "java.lang.Throwable", "Throwable" },
        .{ "java.lang.Error", "Error" },
        .{ "java.lang.AssertionError", "AssertionError" },
        .{ "java.lang.StackOverflowError", "StackOverflowError" },
        .{ "java.lang.OutOfMemoryError", "OutOfMemoryError" },
        .{ "java.lang.Exception", "Exception" },
        .{ "java.lang.RuntimeException", "RuntimeException" },
        .{ "java.lang.ArithmeticException", "ArithmeticException" },
        .{ "java.lang.IllegalArgumentException", "IllegalArgumentException" },
        .{ "java.lang.IllegalStateException", "IllegalStateException" },
        .{ "java.lang.IndexOutOfBoundsException", "IndexOutOfBoundsException" },
        .{ "java.lang.NumberFormatException", "NumberFormatException" },
        .{ "java.lang.UnsupportedOperationException", "UnsupportedOperationException" },
        .{ "java.lang.ClassCastException", "ClassCastException" },
        .{ "java.lang.NullPointerException", "NullPointerException" },
        .{ "java.io.IOException", "IOException" },
        .{ "java.io.FileNotFoundException", "FileNotFoundException" },
        .{ "java.io.EOFException", "EOFException" },
        .{ "clojure.lang.ExceptionInfo", "ExceptionInfo" },
    });
    return fqcn_map.get(class_name) orelse class_name;
}

// Tests
const testing = std.testing;

test "isSubclassOf — exact match" {
    try testing.expect(isSubclassOf("Exception", "Exception"));
    try testing.expect(isSubclassOf("ArithmeticException", "ArithmeticException"));
}

test "isSubclassOf — direct parent" {
    try testing.expect(isSubclassOf("RuntimeException", "Exception"));
    try testing.expect(isSubclassOf("ArithmeticException", "RuntimeException"));
    try testing.expect(isSubclassOf("IOException", "Exception"));
    try testing.expect(isSubclassOf("Error", "Throwable"));
}

test "isSubclassOf — transitive parent" {
    try testing.expect(isSubclassOf("ArithmeticException", "Exception"));
    try testing.expect(isSubclassOf("ArithmeticException", "Throwable"));
    try testing.expect(isSubclassOf("FileNotFoundException", "Exception"));
    try testing.expect(isSubclassOf("FileNotFoundException", "Throwable"));
    try testing.expect(isSubclassOf("NumberFormatException", "RuntimeException"));
    try testing.expect(isSubclassOf("NumberFormatException", "Throwable"));
}

test "isSubclassOf — not related" {
    try testing.expect(!isSubclassOf("ArithmeticException", "IOException"));
    try testing.expect(!isSubclassOf("IOException", "RuntimeException"));
    try testing.expect(!isSubclassOf("Exception", "RuntimeException"));
    try testing.expect(!isSubclassOf("Error", "Exception"));
}

test "isSubclassOf — unknown class" {
    try testing.expect(!isSubclassOf("CustomException", "Exception"));
}

test "isKnownException" {
    try testing.expect(isKnownException("Exception"));
    try testing.expect(isKnownException("ArithmeticException"));
    try testing.expect(!isKnownException("CustomFoo"));
}

test "getParent" {
    try testing.expectEqualStrings("RuntimeException", getParent("ArithmeticException").?);
    try testing.expectEqualStrings("Exception", getParent("RuntimeException").?);
    try testing.expectEqualStrings("Throwable", getParent("Exception").?);
    try testing.expect(getParent("Throwable") == null);
    try testing.expect(getParent("UnknownClass") == null);
}
