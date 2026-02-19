// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! ClassDef registry — unified per-class definition for Java interop.
//!
//! Each Java class is described by a `ClassDef` struct containing its FQCN,
//! aliases, constructor, method dispatch, and instance check functions.
//! The registry aggregates all class definitions in one comptime array.
//!
//! Adding a new class = 1 new file + 1 line in `registry`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../runtime/value.zig");
const Value = value_mod.Value;

// Class implementations
const uri_class = @import("classes/uri.zig");
const file_class = @import("classes/file.zig");
const uuid_class = @import("classes/uuid.zig");
const pushback_reader_class = @import("classes/pushback_reader.zig");
const string_builder_class = @import("classes/string_builder.zig");
const string_writer_class = @import("classes/string_writer.zig");
const buffered_writer_class = @import("classes/buffered_writer.zig");

/// Function type for class constructors: (allocator, args) -> Value
pub const ConstructorFn = fn (Allocator, []const Value) anyerror!Value;

/// Function type for instance method dispatch: (allocator, method, obj, rest) -> Value
pub const DispatchMethodFn = fn (Allocator, []const u8, Value, []const Value) anyerror!Value;

/// Function type for instance? check: (x) -> bool
pub const InstanceCheckFn = fn (Value) bool;

/// Unified per-class definition.
pub const ClassDef = struct {
    /// Fully qualified class name (e.g., "java.net.URI")
    fqcn: []const u8,
    /// Short aliases (e.g., &.{"URI"})
    aliases: []const []const u8,
    /// Constructor function, or null if not constructable
    constructor: ?*const ConstructorFn,
    /// Instance method dispatch, or null if no methods
    dispatch_method: ?*const DispatchMethodFn,
    /// Custom instance? check, or null (falls back to __reify_type match)
    instance_check: ?*const InstanceCheckFn,
};

/// The global class registry. All Java interop classes are registered here.
/// To add a new class: create a class file in classes/, add one entry here.
pub const registry = [_]ClassDef{
    // java.net.URI
    .{
        .fqcn = uri_class.class_name,
        .aliases = &.{"URI"},
        .constructor = &uri_class.construct,
        .dispatch_method = &uri_class.dispatchMethod,
        .instance_check = null,
    },
    // java.io.File
    .{
        .fqcn = file_class.class_name,
        .aliases = &.{"File"},
        .constructor = &file_class.construct,
        .dispatch_method = &file_class.dispatchMethod,
        .instance_check = null,
    },
    // java.util.UUID
    .{
        .fqcn = uuid_class.class_name,
        .aliases = &.{"UUID"},
        .constructor = &uuid_class.construct,
        .dispatch_method = &uuid_class.dispatchMethod,
        .instance_check = null,
    },
    // java.io.PushbackReader
    .{
        .fqcn = pushback_reader_class.class_name,
        .aliases = &.{"PushbackReader"},
        .constructor = &pushback_reader_class.construct,
        .dispatch_method = &pushback_reader_class.dispatchMethod,
        .instance_check = null,
    },
    // java.io.StringReader (constructor alias, same dispatch as PushbackReader)
    .{
        .fqcn = pushback_reader_class.string_reader_class_name,
        .aliases = &.{"StringReader"},
        .constructor = &pushback_reader_class.constructStringReader,
        .dispatch_method = null, // dispatched via PushbackReader's __reify_type
        .instance_check = null,
    },
    // java.lang.StringBuilder
    .{
        .fqcn = string_builder_class.class_name,
        .aliases = &.{"StringBuilder"},
        .constructor = &string_builder_class.construct,
        .dispatch_method = &string_builder_class.dispatchMethod,
        .instance_check = null,
    },
    // java.io.StringWriter
    .{
        .fqcn = string_writer_class.class_name,
        .aliases = &.{"StringWriter"},
        .constructor = &string_writer_class.construct,
        .dispatch_method = &string_writer_class.dispatchMethod,
        .instance_check = null,
    },
    // java.io.BufferedWriter
    .{
        .fqcn = buffered_writer_class.class_name,
        .aliases = &.{"BufferedWriter"},
        .constructor = &buffered_writer_class.construct,
        .dispatch_method = &buffered_writer_class.dispatchMethod,
        .instance_check = null,
    },
};

/// Look up a ClassDef by FQCN.
pub fn findByFqcn(fqcn: []const u8) ?*const ClassDef {
    for (&registry) |*def| {
        if (std.mem.eql(u8, def.fqcn, fqcn)) return def;
    }
    return null;
}

/// Look up a ClassDef by alias (short name like "URI", "File").
pub fn findByAlias(alias: []const u8) ?*const ClassDef {
    for (&registry) |*def| {
        for (def.aliases) |a| {
            if (std.mem.eql(u8, a, alias)) return def;
        }
    }
    return null;
}

/// Look up a ClassDef by either FQCN or alias.
pub fn find(name: []const u8) ?*const ClassDef {
    return findByFqcn(name) orelse findByAlias(name);
}

/// Dispatch a constructor call. Returns null if class not found.
pub fn construct(allocator: Allocator, class_name: []const u8, args: []const Value) ?anyerror!Value {
    const def = find(class_name) orelse return null;
    const ctor = def.constructor orelse return null;
    return ctor(allocator, args);
}

/// Dispatch an instance method on a class instance identified by __reify_type.
/// Returns null if class not found in registry.
pub fn dispatchMethod(allocator: Allocator, reify_type: []const u8, method: []const u8, obj: Value, rest: []const Value) ?anyerror!Value {
    const def = findByFqcn(reify_type) orelse return null;
    const dispatch_fn = def.dispatch_method orelse return null;
    return dispatch_fn(allocator, method, obj, rest);
}

/// Check if value is an instance of the given class.
/// For map-backed classes, checks __reify_type match.
pub fn isInstance(class_name: []const u8, x: Value) bool {
    const def = find(class_name) orelse return false;

    // Custom instance check takes priority
    if (def.instance_check) |check_fn| {
        return check_fn(x);
    }

    // Default: check __reify_type on maps
    const dispatch = @import("dispatch.zig");
    if (dispatch.getReifyType(x)) |rt| {
        return std.mem.eql(u8, rt, def.fqcn);
    }
    return false;
}

// Tests
const testing = std.testing;

test "findByFqcn — known class" {
    const def = findByFqcn("java.net.URI");
    try testing.expect(def != null);
    try testing.expectEqualStrings("java.net.URI", def.?.fqcn);
}

test "findByAlias — known alias" {
    const def = findByAlias("URI");
    try testing.expect(def != null);
    try testing.expectEqualStrings("java.net.URI", def.?.fqcn);
}

test "find — by alias or fqcn" {
    try testing.expect(find("URI") != null);
    try testing.expect(find("java.net.URI") != null);
    try testing.expect(find("File") != null);
    try testing.expect(find("java.io.File") != null);
    try testing.expect(find("NonExistent") == null);
}

test "registry — all entries have fqcn and aliases" {
    for (registry) |def| {
        try testing.expect(def.fqcn.len > 0);
        try testing.expect(def.aliases.len > 0);
    }
}

test "construct — via registry" {
    const alloc = std.heap.page_allocator;
    const uri_str = Value.initString(alloc, "https://example.com");
    const result = construct(alloc, "java.net.URI", &.{uri_str});
    try testing.expect(result != null);
    const val = try result.?;
    try testing.expect(val.tag() == .map);
}

test "construct — unknown class" {
    const alloc = std.heap.page_allocator;
    try testing.expect(construct(alloc, "NonExistent", &.{}) == null);
}
