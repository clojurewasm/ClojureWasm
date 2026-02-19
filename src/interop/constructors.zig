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
const buffered_writer_class = @import("classes/buffered_writer.zig");

/// Known class name mappings: short name -> fully qualified name.
pub const known_classes = std.StaticStringMap([]const u8).initComptime(.{
    .{ "URI", "java.net.URI" },
    .{ "File", "java.io.File" },
    .{ "UUID", "java.util.UUID" },
    .{ "PushbackReader", "java.io.PushbackReader" },
    .{ "StringReader", "java.io.StringReader" },
    .{ "StringBuilder", "java.lang.StringBuilder" },
    .{ "StringWriter", "java.io.StringWriter" },
    .{ "BufferedWriter", "java.io.BufferedWriter" },
    .{ "EOFException", "java.io.EOFException" },
    .{ "IOException", "java.io.IOException" },
    .{ "FileNotFoundException", "java.io.FileNotFoundException" },
    .{ "Exception", "Exception" },
    .{ "RuntimeException", "RuntimeException" },
    .{ "IllegalArgumentException", "IllegalArgumentException" },
    .{ "IllegalStateException", "IllegalStateException" },
    .{ "ArithmeticException", "ArithmeticException" },
    .{ "NumberFormatException", "NumberFormatException" },
    .{ "IndexOutOfBoundsException", "IndexOutOfBoundsException" },
    .{ "UnsupportedOperationException", "UnsupportedOperationException" },
    .{ "ClassCastException", "ClassCastException" },
    .{ "NullPointerException", "NullPointerException" },
    .{ "StackOverflowError", "StackOverflowError" },
    .{ "AssertionError", "AssertionError" },
    .{ "Error", "Error" },
    .{ "ExceptionInfo", "ExceptionInfo" },
});

/// Resolve a short class name to its fully qualified name.
/// Returns the input if already fully qualified or if it's a known short name.
pub fn resolveClassName(name: []const u8) ?[]const u8 {
    return known_classes.get(name);
}

/// Map FQCN or short name to simple exception type name.
/// Returns null if the class is not an exception type.
fn isExceptionClass(class_name: []const u8) ?[]const u8 {
    const map = std.StaticStringMap([]const u8).initComptime(.{
        .{ "Exception", "Exception" },
        .{ "java.lang.Exception", "Exception" },
        .{ "RuntimeException", "RuntimeException" },
        .{ "java.lang.RuntimeException", "RuntimeException" },
        .{ "IllegalArgumentException", "IllegalArgumentException" },
        .{ "java.lang.IllegalArgumentException", "IllegalArgumentException" },
        .{ "IllegalStateException", "IllegalStateException" },
        .{ "java.lang.IllegalStateException", "IllegalStateException" },
        .{ "ArithmeticException", "ArithmeticException" },
        .{ "java.lang.ArithmeticException", "ArithmeticException" },
        .{ "NumberFormatException", "NumberFormatException" },
        .{ "java.lang.NumberFormatException", "NumberFormatException" },
        .{ "IndexOutOfBoundsException", "IndexOutOfBoundsException" },
        .{ "java.lang.IndexOutOfBoundsException", "IndexOutOfBoundsException" },
        .{ "UnsupportedOperationException", "UnsupportedOperationException" },
        .{ "java.lang.UnsupportedOperationException", "UnsupportedOperationException" },
        .{ "ClassCastException", "ClassCastException" },
        .{ "java.lang.ClassCastException", "ClassCastException" },
        .{ "NullPointerException", "NullPointerException" },
        .{ "java.lang.NullPointerException", "NullPointerException" },
        .{ "IOException", "IOException" },
        .{ "java.io.IOException", "IOException" },
        .{ "FileNotFoundException", "FileNotFoundException" },
        .{ "java.io.FileNotFoundException", "FileNotFoundException" },
        .{ "EOFException", "EOFException" },
        .{ "java.io.EOFException", "EOFException" },
        .{ "StackOverflowError", "StackOverflowError" },
        .{ "java.lang.StackOverflowError", "StackOverflowError" },
        .{ "AssertionError", "AssertionError" },
        .{ "java.lang.AssertionError", "AssertionError" },
        .{ "Error", "Error" },
        .{ "java.lang.Error", "Error" },
    });
    return map.get(class_name);
}

/// Build an exception map: {:__ex_info true :message msg :data {} :cause cause :__ex_type type}
/// Follows the same format as VM's createRuntimeException (vm.zig).
/// ctor_args: 0 args (no message), 1 arg (message), 2 args (message + cause).
pub fn makeExceptionMap(allocator: Allocator, ex_type_name: []const u8, ctor_args: []const Value) anyerror!Value {
    const msg_val: Value = if (ctor_args.len >= 1) ctor_args[0] else Value.nil_val;
    const cause_val: Value = if (ctor_args.len >= 2) ctor_args[1] else Value.nil_val;

    const runtime_collections = @import("../runtime/collections.zig");
    const entries = try allocator.alloc(Value, 10);

    const empty_map = try allocator.create(runtime_collections.PersistentArrayMap);
    empty_map.* = .{ .entries = &.{} };

    entries[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_info" });
    entries[1] = Value.true_val;
    entries[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
    entries[3] = msg_val;
    entries[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "data" });
    entries[5] = Value.initMap(empty_map);
    entries[6] = Value.initKeyword(allocator, .{ .ns = null, .name = "cause" });
    entries[7] = cause_val;
    entries[8] = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_type" });
    entries[9] = Value.initString(allocator, try allocator.dupe(u8, ex_type_name));

    const map = try allocator.create(runtime_collections.PersistentArrayMap);
    map.* = .{ .entries = entries };
    return Value.initMap(map);
}

/// __interop-new — Java class constructor dispatch.
/// Called as (__interop-new "fqcn" args...).
fn interopNewFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err.setErrorFmt(.eval, .arity_error, .{}, "Constructor requires at least a class name", .{});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "Constructor: first arg must be class name string", .{});
    const class_name = args[0].asString();
    const ctor_args = args[1..];

    // Exception constructor: (Exception. "message") or (Exception. "message" cause)
    // Returns exception map: {:__ex_info true :message msg :data {} :cause nil :__ex_type type}
    if (isExceptionClass(class_name)) |ex_type_name| {
        return makeExceptionMap(allocator, ex_type_name, ctor_args);
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
    if (std.mem.eql(u8, class_name, buffered_writer_class.class_name)) {
        return buffered_writer_class.construct(allocator, ctor_args);
    }

    return err.setErrorFmt(
        .eval,
        .value_error,
        .{},
        "Unknown class: {s}. Supported: URI, File, UUID, PushbackReader, StringReader, StringBuilder, StringWriter, BufferedWriter, Exception, ExceptionInfo",
        .{class_name},
    );
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

test "Exception constructor returns exception map" {
    const allocator = std.heap.page_allocator;
    const args = [_]Value{
        Value.initString(allocator, "Exception"),
        Value.initString(allocator, "boom"),
    };
    const result = try interopNewFn(allocator, &args);

    // Must be a map, not a raw string
    try testing.expect(result.tag() == .map);

    // Must have :__ex_info key
    const ex_info_key = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_info" });
    const ex_info_val = result.asMap().get(ex_info_key);
    try testing.expect(ex_info_val != null);

    // Must have :message "boom"
    const msg_key = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
    const msg_val = result.asMap().get(msg_key).?;
    try testing.expect(msg_val.tag() == .string);
    try testing.expectEqualStrings("boom", msg_val.asString());

    // Must have :__ex_type "Exception"
    const type_key = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_type" });
    const type_val = result.asMap().get(type_key).?;
    try testing.expect(type_val.tag() == .string);
    try testing.expectEqualStrings("Exception", type_val.asString());
}

test "RuntimeException constructor returns exception map with correct type" {
    const allocator = std.heap.page_allocator;
    const args = [_]Value{
        Value.initString(allocator, "RuntimeException"),
        Value.initString(allocator, "oops"),
    };
    const result = try interopNewFn(allocator, &args);
    try testing.expect(result.tag() == .map);

    const type_key = Value.initKeyword(allocator, .{ .ns = null, .name = "__ex_type" });
    const type_val = result.asMap().get(type_key).?;
    try testing.expectEqualStrings("RuntimeException", type_val.asString());
}

test "Exception constructor with no message" {
    const allocator = std.heap.page_allocator;
    const args = [_]Value{
        Value.initString(allocator, "Exception"),
    };
    const result = try interopNewFn(allocator, &args);
    try testing.expect(result.tag() == .map);

    // Message should be nil or empty
    const msg_key = Value.initKeyword(allocator, .{ .ns = null, .name = "message" });
    const msg_val = result.asMap().get(msg_key).?;
    try testing.expect(msg_val.tag() == .nil);
}
