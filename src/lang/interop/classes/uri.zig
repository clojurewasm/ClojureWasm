// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! java.net.URI — URI parsing and component access.
//!
//! Constructor: (URI. "https://example.com/path?q=1")
//! Instance methods: .getScheme, .getHost, .getPort, .getPath, .getQuery, .getFragment, .toString
//! Static methods: URI/create (same as constructor)

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("../../../runtime/value.zig");
const Value = value_mod.Value;
const err = @import("../../../runtime/error.zig");
const constructors = @import("../constructors.zig");

pub const class_name = "java.net.URI";

/// Construct a URI instance from a string.
/// Returns a PersistentArrayMap with :__reify_type "java.net.URI" and component keys.
pub fn construct(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len != 1) return err.setErrorFmt(.eval, .arity_error, .{}, "URI constructor expects 1 argument, got {d}", .{args.len});
    if (args[0].tag() != .string) return err.setErrorFmt(.eval, .type_error, .{}, "URI constructor expects a string argument", .{});
    const raw = args[0].asString();

    const uri = std.Uri.parse(raw) catch {
        return err.setErrorFmt(.eval, .value_error, .{}, "Malformed URI: {s}", .{raw});
    };

    // Extract components
    const scheme_str = try allocator.dupe(u8, uri.scheme);
    const host_str = if (uri.host) |h| switch (h) {
        .raw => |s| try allocator.dupe(u8, s),
        .percent_encoded => |s| try allocator.dupe(u8, s),
    } else null;
    const port_val: i64 = if (uri.port) |p| @intCast(p) else -1;
    const path_str = switch (uri.path) {
        .raw => |s| try allocator.dupe(u8, s),
        .percent_encoded => |s| try allocator.dupe(u8, s),
    };
    const query_str = if (uri.query) |q| switch (q) {
        .raw => |s| try allocator.dupe(u8, s),
        .percent_encoded => |s| try allocator.dupe(u8, s),
    } else null;
    const fragment_str = if (uri.fragment) |f| switch (f) {
        .raw => |s| try allocator.dupe(u8, s),
        .percent_encoded => |s| try allocator.dupe(u8, s),
    } else null;

    // Build entries: [:__reify_type "java.net.URI" :scheme ... :host ... :port ... :path ... :query ... :fragment ... :raw ...]
    const extra = try allocator.alloc(Value, 14); // 7 key-value pairs
    extra[0] = Value.initKeyword(allocator, .{ .ns = null, .name = "scheme" });
    extra[1] = Value.initString(allocator, scheme_str);
    extra[2] = Value.initKeyword(allocator, .{ .ns = null, .name = "host" });
    extra[3] = if (host_str) |h| Value.initString(allocator, h) else Value.nil_val;
    extra[4] = Value.initKeyword(allocator, .{ .ns = null, .name = "port" });
    extra[5] = Value.initInteger(port_val);
    extra[6] = Value.initKeyword(allocator, .{ .ns = null, .name = "path" });
    extra[7] = Value.initString(allocator, path_str);
    extra[8] = Value.initKeyword(allocator, .{ .ns = null, .name = "query" });
    extra[9] = if (query_str) |q| Value.initString(allocator, q) else Value.nil_val;
    extra[10] = Value.initKeyword(allocator, .{ .ns = null, .name = "fragment" });
    extra[11] = if (fragment_str) |f| Value.initString(allocator, f) else Value.nil_val;
    extra[12] = Value.initKeyword(allocator, .{ .ns = null, .name = "raw" });
    extra[13] = Value.initString(allocator, try allocator.dupe(u8, raw));

    return constructors.makeClassInstance(allocator, class_name, extra);
}

/// Dispatch instance method on a URI object.
pub fn dispatchMethod(allocator: Allocator, method: []const u8, obj: Value, rest: []const Value) anyerror!Value {
    _ = rest;
    const map = obj.asMap();

    if (std.mem.eql(u8, method, "getScheme")) {
        return getField(map, "scheme");
    } else if (std.mem.eql(u8, method, "getHost")) {
        return getField(map, "host");
    } else if (std.mem.eql(u8, method, "getPort")) {
        return getField(map, "port");
    } else if (std.mem.eql(u8, method, "getPath")) {
        return getField(map, "path");
    } else if (std.mem.eql(u8, method, "getQuery")) {
        return getField(map, "query");
    } else if (std.mem.eql(u8, method, "getFragment")) {
        return getField(map, "fragment");
    } else if (std.mem.eql(u8, method, "toString") or std.mem.eql(u8, method, "toASCIIString")) {
        return getField(map, "raw");
    } else if (std.mem.eql(u8, method, "getAuthority")) {
        // Reconstruct authority from host and port
        const host = getField(map, "host");
        if (host.isNil()) return Value.nil_val;
        const port = getField(map, "port");
        const port_val = port.asInteger();
        if (port_val == -1) return host;
        // host:port
        const host_str = host.asString();
        var buf = std.ArrayList(u8).empty;
        buf.appendSlice(allocator, host_str) catch return error.OutOfMemory;
        buf.append(allocator, ':') catch return error.OutOfMemory;
        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port_val}) catch return error.OutOfMemory;
        buf.appendSlice(allocator, port_str) catch return error.OutOfMemory;
        return Value.initString(allocator, buf.items);
    }

    return err.setErrorFmt(.eval, .value_error, .{}, "No matching method {s} for java.net.URI", .{method});
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

test "URI construct — basic" {
    // Use page_allocator: Value allocations aren't freed individually (GC manages them)
    const allocator = std.heap.page_allocator;
    const raw_str = Value.initString(allocator, "https://example.com/path?q=1#frag");
    const result = try construct(allocator, &.{raw_str});
    try testing.expect(result.tag() == .map);
    // Verify fields
    const map = result.asMap();
    try testing.expectEqualStrings("https", getField(map, "scheme").asString());
    try testing.expectEqualStrings("example.com", getField(map, "host").asString());
    try testing.expectEqualStrings("/path", getField(map, "path").asString());
    try testing.expectEqualStrings("q=1", getField(map, "query").asString());
    try testing.expectEqualStrings("frag", getField(map, "fragment").asString());
    try testing.expect(getField(map, "port").asInteger() == -1);
}
