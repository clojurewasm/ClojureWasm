// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Java interop constructor dispatch — __interop-new builtin.
//!
//! Handles (ClassName. args...) and (new ClassName args...) syntax.
//! The analyzer rewrites these to (__interop-new "fqcn" args...).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;
const var_mod = @import("../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err = @import("../runtime/error.zig");

/// Known class name mappings: short name -> fully qualified name.
pub const known_classes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "URI", "java.net.URI" },
    .{ "File", "java.io.File" },
    .{ "UUID", "java.util.UUID" },
    .{ "Exception", "Exception" },
    .{ "ExceptionInfo", "ExceptionInfo" },
});

/// Resolve a short class name to its fully qualified name.
/// Returns the input if already fully qualified or if it's a known short name.
pub fn resolveClassName(name: []const u8) ?[]const u8 {
    return known_classes.get(name);
}

/// __interop-new — Java class constructor dispatch.
/// Called as (__interop-new "fqcn" args...).
fn interopNewFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Constructor requires at least a class name", .{});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "Constructor: first arg must be class name string", .{});
    const class_name = args[0].asString();
    const ctor_args = args[1..];

    // Exception constructor: (Exception. "message")
    if (std.mem.eql(u8, class_name, "Exception")) {
        if (ctor_args.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Exception requires a message", .{});
        // Just return the message string — throw wraps it in error
        return ctor_args[0];
    }

    // ExceptionInfo constructor: (ExceptionInfo. "message" data)
    if (std.mem.eql(u8, class_name, "ExceptionInfo")) {
        if (ctor_args.len < 1) return err.setErrorFmt(.eval, .value_error, .{}, "ExceptionInfo requires at least a message", .{});
        // Delegate to ex-info builtin behavior
        return err.setErrorFmt(.eval, .value_error, .{}, "Use (ex-info msg map) instead of (ExceptionInfo. msg map)", .{});
    }

    // Class dispatch table — populated in 74.3+
    return err.setErrorFmt(.eval, .value_error, .{}, "Unknown class: {s}", .{class_name});
}

/// Build a class instance map with :__reify_type metadata.
/// Returns a PersistentArrayMap. `extra_entries` should be pre-built key-value pairs.
pub fn makeClassInstance(allocator: Allocator, class_name: []const u8, extra_entries: []const Value) !Value {
    // entries: [:__reify_type class_name, extra_entries...]
    const entry_count = 2 + extra_entries.len;
    const entries = try allocator.alloc(Value, entry_count);

    // :__reify_type key
    entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__reify_type" });
    entries[1] = Value.initString(allocator, try allocator.dupe(u8, class_name));

    @memcpy(entries[2..], extra_entries);

    const runtime_collections = @import("../runtime/collections.zig");
    const map = try allocator.create(runtime_collections.PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value.initMap(map);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "__interop-new",
        .func = &interopNewFn,
        .doc = "Java class constructor dispatch. (ClassName. args...) is rewritten to (__interop-new \"fqcn\" args...).",
        .arglists = "([class-name & args])",
        .added = "1.0",
    },
};

// Tests
const testing = std.testing;

test "resolveClassName — known classes" {
    try testing.expectEqualStrings("java.net.URI", resolveClassName("URI").?);
    try testing.expectEqualStrings("java.io.File", resolveClassName("File").?);
    try testing.expectEqualStrings("java.util.UUID", resolveClassName("UUID").?);
    try testing.expectEqualStrings("Exception", resolveClassName("Exception").?);
}

test "resolveClassName — unknown class" {
    try testing.expect(resolveClassName("Foo") == null);
}
