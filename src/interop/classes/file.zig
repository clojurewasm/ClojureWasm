// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.io.File — File path and filesystem operations.
//!
//! Constructor: (File. path) or (File. parent child)
//! Instance methods: .getName, .getPath, .getParent, .getAbsolutePath,
//!   .exists, .isDirectory, .isFile, .canRead, .canWrite,
//!   .length, .delete, .mkdir, .mkdirs, .list, .toString

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.io.File";

/// Construct a File instance.
/// (File. path) or (File. parent child)
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len == 0 or args.len > 2)
        return err.setErrorFmt(.eval, .arity_error, .{}, "File constructor expects 1 or 2 arguments, got {d}", .{args.len});

    if (args[0].tag() != .string)
        return err.setErrorFmt(.eval, .type_error, .{}, "File constructor expects string path", .{});

    var path: []const u8 = undefined;
    if (args.len == 1) {
        path = args[0].asString();
    } else {
        // (File. parent child) — join paths
        if (args[1].tag() != .string)
            return err.setErrorFmt(.eval, .type_error, .{}, "File constructor: child must be a string", .{});
        const parent = args[0].asString();
        const child = args[1].asString();
        const joined = try std.fs.path.join(allocator, &.{ parent, child });
        path = joined;
    }

    // Build map entries: [:path path_str]
    const extra = try allocator.alloc(Value, 2);
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "path" });
    extra[1] = Value.initString(allocator, try allocator.dupe(u8, path));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Dispatch instance method on a File object.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    _ = rest;
    const map = obj.asMap();
    const path = getField(map, "path").asString();

    if (std.mem.eql(u8, method, "getPath") or std.mem.eql(u8, method, "toString")) {
        return Value.initString(allocator, path);
    } else if (std.mem.eql(u8, method, "getName")) {
        const name = std.fs.path.basename(path);
        return Value.initString(allocator, try allocator.dupe(u8, name));
    } else if (std.mem.eql(u8, method, "getParent")) {
        if (std.fs.path.dirname(path)) |parent| {
            return Value.initString(allocator, try allocator.dupe(u8, parent));
        }
        return Value.nil_val;
    } else if (std.mem.eql(u8, method, "getAbsolutePath")) {
        const cwd = std.fs.cwd();
        const abs = cwd.realpathAlloc(allocator, path) catch {
            // If path doesn't exist, try to construct absolute from cwd
            if (std.fs.path.isAbsolute(path)) {
                return Value.initString(allocator, try allocator.dupe(u8, path));
            }
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd_path = cwd.realpath(".", &buf) catch return Value.initString(allocator, try allocator.dupe(u8, path));
            const joined = try std.fs.path.join(allocator, &.{ cwd_path, path });
            return Value.initString(allocator, joined);
        };
        return Value.initString(allocator, abs);
    } else if (std.mem.eql(u8, method, "exists")) {
        const cwd = std.fs.cwd();
        if (std.fs.path.isAbsolute(path)) {
            const stat = std.fs.openDirAbsolute(path, .{});
            if (stat) |d| {
                var dir = d;
                dir.close();
                return Value.true_val;
            } else |_| {}
            // Try as file
            const file = std.fs.openFileAbsolute(path, .{}) catch return Value.false_val;
            file.close();
            return Value.true_val;
        }
        // Relative path
        _ = cwd.statFile(path) catch return Value.false_val;
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "isDirectory")) {
        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch return Value.false_val;
        return Value.initBoolean(stat.kind == .directory);
    } else if (std.mem.eql(u8, method, "isFile")) {
        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch return Value.false_val;
        return Value.initBoolean(stat.kind == .file);
    } else if (std.mem.eql(u8, method, "canRead")) {
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{}) catch return Value.false_val;
        file.close();
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "canWrite")) {
        const cwd = std.fs.cwd();
        const file = cwd.openFile(path, .{ .mode = .write_only }) catch return Value.false_val;
        file.close();
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "length")) {
        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch return Value.initInteger(0);
        return Value.initInteger(@intCast(stat.size));
    } else if (std.mem.eql(u8, method, "delete")) {
        const cwd = std.fs.cwd();
        cwd.deleteFile(path) catch {
            cwd.deleteDir(path) catch return Value.false_val;
        };
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "mkdir")) {
        const cwd = std.fs.cwd();
        cwd.makeDir(path) catch return Value.false_val;
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "mkdirs")) {
        const cwd = std.fs.cwd();
        cwd.makePath(path) catch return Value.false_val;
        return Value.true_val;
    } else if (std.mem.eql(u8, method, "list")) {
        return listDir(allocator, path);
    } else if (std.mem.eql(u8, method, "lastModified")) {
        const cwd = std.fs.cwd();
        const stat = cwd.statFile(path) catch return Value.initInteger(0);
        // Convert nanoseconds to milliseconds
        const mtime_ns: i128 = stat.mtime;
        const mtime_ms: i64 = @intCast(@divTrunc(mtime_ns, 1_000_000));
        return Value.initInteger(mtime_ms);
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for java.io.File", .{method});
}

/// List directory entries, returning a Clojure vector of filename strings.
fn listDir(allocator: Allocator, path: []const u8) anyerror!Value {
    const cwd = std.fs.cwd();
    var dir = cwd.openDir(path, .{ .iterate = true }) catch return Value.nil_val;
    defer dir.close();

    var names = std.ArrayList(Value).empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        const name = try allocator.dupe(u8, entry.name);
        try names.append(allocator, Value.initString(allocator, name));
    }

    const runtime_collections = @import("../../runtime/collections.zig");
    const vec = try allocator.create(runtime_collections.PersistentVector);
    vec.* = .{ .items = try names.toOwnedSlice(allocator) };
    return Value.initVector(vec);
}

/// Helper: get a keyword field from a PersistentArrayMap by name.
fn getField(map: *const value_mod.PersistentArrayMap, name: []const u8) Value {
    var i: usize = 0;
    while (i + 1 < map.entries.len) : (i += 2) {
        if (map.entries[i].tag() == .keyword) {
            const kw = map.entries[i].asKeyword();
            if (kw.ns == null and std.mem.eql(u8, kw.name, name)) {
                return map.entries[i + 1];
            }
        }
    }
    return Value.nil_val;
}

// Tests
const testing = std.testing;

test "File construct — single path" {
    const allocator = std.heap.page_allocator;
    const path_val = Value.initString(allocator, "/tmp/test.txt");
    const result = try construct(allocator, &.{path_val});
    try testing.expect(result.tag() == .map);
}

test "File construct — parent + child" {
    const allocator = std.heap.page_allocator;
    const parent = Value.initString(allocator, "/tmp");
    const child = Value.initString(allocator, "test.txt");
    const result = try construct(allocator, &.{ parent, child });
    try testing.expect(result.tag() == .map);
}
