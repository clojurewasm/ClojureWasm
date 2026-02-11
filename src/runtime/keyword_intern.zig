// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! Keyword intern table — tracks all keywords created during execution.
//! Used by find-keyword to check if a keyword has been interned.
//! Single-threaded; global mutable state (known exception to D3).

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

/// Global keyword intern table.
/// Keys are "ns/name" or "name" strings, owned by this table.
/// Protected by mutex for thread-safe access.
var table: std.StringArrayHashMapUnmanaged(void) = .empty;
var intern_allocator: ?Allocator = null;
var mutex: std.Thread.Mutex = .{};

/// Initialize the intern table with an allocator.
/// Must be called once before any intern/find operations.
pub fn init(allocator: Allocator) void {
    intern_allocator = allocator;
}

/// Free all interned keyword strings and the table itself.
pub fn deinit() void {
    const alloc = intern_allocator orelse return;
    for (table.keys()) |key| {
        alloc.free(key);
    }
    table.deinit(alloc);
    table = .empty;
    intern_allocator = null;
}

/// Intern a keyword (ns, name). Registers it in the table.
/// Silently fails if not initialized or on alloc failure.
pub fn intern(ns: ?[]const u8, name: []const u8) void {
    const alloc = intern_allocator orelse return;
    const key = formatKey(alloc, ns, name) catch return;
    mutex.lock();
    defer mutex.unlock();
    if (table.contains(key)) {
        alloc.free(key);
        return;
    }
    table.put(alloc, key, {}) catch {
        alloc.free(key);
    };
}

/// Check if a keyword has been interned.
pub fn contains(ns: ?[]const u8, name: []const u8) bool {
    const alloc = intern_allocator orelse return false;
    const key = formatKey(alloc, ns, name) catch return false;
    defer alloc.free(key);
    mutex.lock();
    defer mutex.unlock();
    return table.contains(key);
}

/// Format a keyword as "ns/name" or "name" string for use as hash key.
fn formatKey(alloc: Allocator, ns: ?[]const u8, name: []const u8) ![]u8 {
    if (ns) |n| {
        const key = try alloc.alloc(u8, n.len + 1 + name.len);
        @memcpy(key[0..n.len], n);
        key[n.len] = '/';
        @memcpy(key[n.len + 1 ..], name);
        return key;
    } else {
        return try alloc.dupe(u8, name);
    }
}
