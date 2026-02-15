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
const uri_class = @import("classes/uri.zig");
const file_class = @import("classes/file.zig");
const uuid_class = @import("classes/uuid.zig");
const pushback_reader_class = @import("classes/pushback_reader.zig");
const string_builder_class = @import("classes/string_builder.zig");
const string_writer_class = @import("classes/string_writer.zig");

/// Known class name mappings: short name -> fully qualified name.
pub const known_classes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "URI", "java.net.URI" },
    .{ "File", "java.io.File" },
    .{ "UUID", "java.util.UUID" },
    .{ "PushbackReader", "java.io.PushbackReader" },
    .{ "StringReader", "java.io.StringReader" },
    .{ "StringBuilder", "java.lang.StringBuilder" },
    .{ "StringWriter", "java.io.StringWriter" },
    .{ "EOFException", "java.io.EOFException" },
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
fn interopNewFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Constructor requires at least a class name", .{});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "Constructor: first arg must be class name string", .{});
    const class_name = args[0].asString();
    const ctor_args = args[1..];

    // Exception constructor: (Exception. "message")
    if (std.mem.eql(u8, class_name, "Exception") or
        std.mem.eql(u8, class_name, "java.io.EOFException") or
        std.mem.eql(u8, class_name, "RuntimeException") or
        std.mem.eql(u8, class_name, "IllegalArgumentException"))
    {
        if (ctor_args.len == 0) return err.setErrorFmt(.eval, .value_error, .{}, "Exception requires a message", .{});
        return ctor_args[0];
    }

    // ExceptionInfo constructor: (ExceptionInfo. "message" data)
    if (std.mem.eql(u8, class_name, "ExceptionInfo")) {
        if (ctor_args.len < 1) return err.setErrorFmt(.eval, .value_error, .{}, "ExceptionInfo requires at least a message", .{});
        return err.setErrorFmt(.eval, .value_error, .{}, "Use (ex-info msg map) instead of (ExceptionInfo. msg map)", .{});
    }

    // Class dispatch table
    if (std.mem.eql(u8, class_name, uri_class.class_name)) {
        return uri_class.construct(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, file_class.class_name)) {
        return file_class.construct(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, uuid_class.class_name)) {
        return uuid_class.construct(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, pushback_reader_class.class_name)) {
        return pushback_reader_class.construct(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, pushback_reader_class.string_reader_class_name)) {
        return pushback_reader_class.constructStringReader(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, string_builder_class.class_name)) {
        return string_builder_class.construct(allocator, ctor_args);
    }
    if (std.mem.eql(u8, class_name, string_writer_class.class_name)) {
        return string_writer_class.construct(allocator, ctor_args);
    }

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

/// URI/create — same as URI constructor (no checked exception).
fn uriCreateFn(allocator: Allocator, args: []const Value) anyerror!Value {
    return uri_class.construct(allocator, args);
}

/// UUID/randomUUID — generate random UUID v4.
fn uuidRandomUuidFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 0) return err.setErrorFmt(.eval, .arity_error, .{}, "UUID/randomUUID takes no args, got {d}", .{args.len});
    return uuid_class.randomUUID(allocator);
}

/// UUID/fromString — parse UUID from string.
fn uuidFromStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "UUID/fromString expects 1 arg, got {d}", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "UUID/fromString expects a string arg", .{});
    return uuid_class.constructFromString(allocator, args[0].asString());
}

/// __inst-from-string — create a Date instance from an RFC3339 string.
/// Used by construct-date in clojure.instant and the #inst reader tag.
fn instFromStringFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "__inst-from-string expects 1 arg, got {d}", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "__inst-from-string expects a string arg", .{});
    const s = args[0].asString();
    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "inst" });
    extra[1] = Value.initString(allocator, try allocator.dupe(u8, s));
    return makeClassInstance(allocator, "java.util.Date", extra);
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "__interop-new",
        .func = &interopNewFn,
        .doc = "Java class constructor dispatch. (ClassName. args...) is rewritten to (__interop-new \"fqcn\" args...).",
        .arglists = "([class-name & args])",
        .added = "1.0",
    },
    .{
        .name = "__uri-create",
        .func = &uriCreateFn,
        .doc = "URI/create — creates a URI from a string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "__uuid-random-uuid",
        .func = &uuidRandomUuidFn,
        .doc = "UUID/randomUUID — generate a random UUID v4.",
        .arglists = "([])",
        .added = "1.0",
    },
    .{
        .name = "__uuid-from-string",
        .func = &uuidFromStringFn,
        .doc = "UUID/fromString — parse UUID from string.",
        .arglists = "([s])",
        .added = "1.0",
    },
    .{
        .name = "__inst-from-string",
        .func = &instFromStringFn,
        .doc = "Create a Date instance from an RFC3339 timestamp string.",
        .arglists = "([s])",
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
