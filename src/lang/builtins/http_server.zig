// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! cljw.http — HTTP server with Ring-compatible handler model.
//!
//! Provides a basic HTTP/1.1 server that calls a Clojure handler function
//! for each request. The handler receives a Ring-style request map and
//! returns a Ring-style response map.
//!
//! Usage from Clojure:
//!   (require '[cljw.http :as http])
//!   (defn handler [req] {:status 200 :body "Hello"})
//!   (http/run-server handler {:port 8080})

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../../runtime/value.zig").Value;
const PersistentArrayMap = @import("../../runtime/value.zig").PersistentArrayMap;
const collections = @import("../../runtime/collections.zig");
const bootstrap = @import("../../engine/bootstrap.zig");
const dispatch = @import("../../runtime/dispatch.zig");
const var_mod = @import("../../runtime/var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err_mod = @import("../../runtime/error.zig");
const Env = @import("../../runtime/env.zig").Env;
const lifecycle = @import("../../runtime/lifecycle.zig");

// ============================================================
// Build mode flag
// ============================================================

/// When true, run-server returns immediately (used during `cljw build` to
/// allow require resolution without blocking on the accept loop).
pub var build_mode: bool = false;

/// When true, run-server starts the accept loop in a background thread
/// and returns immediately (used with --nrepl so nREPL can start after eval).
pub var background_mode: bool = false;

// ============================================================
// Server state
// ============================================================

// Network-bound server state. The std.net APIs were removed in Zig 0.16; the
// listener field's old type (std.net.Server) is no longer available. The
// server runtime is stubbed below until the std.Io.net migration lands as
// a follow-up task. The state struct is kept so that the public API surface
// (run-server / set-handler!) doesn't change shape.

/// Module-level storage for background server (nREPL mode).
var bg_server: ?ServerState = null;

const ServerState = struct {
    env: *Env,
    handler: Value,
    alloc: Allocator,
    running: bool,
    port: u16,
};

// ============================================================
// Builtins
// ============================================================

/// (run-server handler opts) — stubbed during the Zig 0.16 migration.
/// std.net.Address/Server/Stream were all removed; the std.Io.net replacement
/// requires substantial rework (futex-based accept, no acceptWithShutdownCheck,
/// stream reader/writer interface). Tracked as a Phase 7 follow-up F## item.
pub fn runServerFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to run-server", .{args.len});
    if (build_mode) return Value.nil_val;
    return err_mod.setError(.{
        .kind = .internal_error,
        .phase = .eval,
        .message = "run-server: HTTP server is temporarily disabled while the std.net → std.Io.net migration is in progress",
    });
}

// ============================================================
// HTTP request parsing
// ============================================================

const ParsedRequest = struct {
    method: []const u8,
    uri: []const u8,
    query_string: ?[]const u8,
    headers: [64]Header,
    header_count: usize,
    body: ?[]const u8,
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

fn parseHttpRequest(raw: []const u8) ?ParsedRequest {
    var result: ParsedRequest = .{
        .method = "",
        .uri = "",
        .query_string = null,
        .headers = undefined,
        .header_count = 0,
        .body = null,
    };

    // Find end of request line
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return null;
    const request_line = raw[0..line_end];

    // Parse: METHOD URI HTTP/x.x
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    result.method = parts.next() orelse return null;
    const full_uri = parts.next() orelse return null;

    // Split URI and query string
    if (std.mem.indexOf(u8, full_uri, "?")) |qpos| {
        result.uri = full_uri[0..qpos];
        result.query_string = full_uri[qpos + 1 ..];
    } else {
        result.uri = full_uri;
    }

    // Parse headers
    var pos = line_end + 2;
    var content_length: usize = 0;
    while (pos < raw.len) {
        const hdr_end = std.mem.indexOf(u8, raw[pos..], "\r\n") orelse break;
        if (hdr_end == 0) {
            // Empty line = end of headers
            pos += 2;
            break;
        }
        const header_line = raw[pos .. pos + hdr_end];
        if (std.mem.indexOf(u8, header_line, ": ")) |colon_pos| {
            if (result.header_count < result.headers.len) {
                const name = header_line[0..colon_pos];
                const value = header_line[colon_pos + 2 ..];
                result.headers[result.header_count] = .{ .name = name, .value = value };
                result.header_count += 1;

                // Check Content-Length
                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                }
            }
        }
        pos += hdr_end + 2;
    }

    // Body
    if (content_length > 0 and pos + content_length <= raw.len) {
        result.body = raw[pos .. pos + content_length];
    }

    return result;
}

// ============================================================
// Ring request map construction (kept for future restoration; the remote
// address argument no longer carries a network type since the server is
// stubbed for the migration).
// ============================================================

fn buildRingRequest(allocator: Allocator, parsed: ParsedRequest, server_port: u16, remote_addr: []const u8) !Value {
    // Build headers map
    const hdr_entries = try allocator.alloc(Value, parsed.header_count * 2);
    for (0..parsed.header_count) |i| {
        // Ring uses lowercase header names
        const lower = try allocator.alloc(u8, parsed.headers[i].name.len);
        for (parsed.headers[i].name, 0..) |c, j| {
            lower[j] = std.ascii.toLower(c);
        }
        hdr_entries[i * 2] = Value.initString(allocator, lower);
        const val_dup = try allocator.dupe(u8, parsed.headers[i].value);
        hdr_entries[i * 2 + 1] = Value.initString(allocator, val_dup);
    }
    const hdr_map = try allocator.create(PersistentArrayMap);
    hdr_map.* = .{ .entries = hdr_entries };

    // Convert method to lowercase keyword (Ring convention)
    var method_lower_buf: [16]u8 = undefined;
    const method_len = @min(parsed.method.len, method_lower_buf.len);
    for (parsed.method[0..method_len], 0..) |c, i| {
        method_lower_buf[i] = std.ascii.toLower(c);
    }
    const method_str = try allocator.dupe(u8, method_lower_buf[0..method_len]);

    const addr_dup = try allocator.dupe(u8, remote_addr);

    // URI and query string
    const uri_dup = try allocator.dupe(u8, parsed.uri);

    // Build request map entries
    // :server-port, :server-name, :remote-addr, :uri, :query-string,
    // :request-method, :headers, :body
    var entry_count: usize = 14; // 7 keys * 2
    if (parsed.query_string != null) entry_count += 2;
    if (parsed.body != null) entry_count += 2;
    // Adjust: base = :server-port, :server-name, :remote-addr, :uri, :request-method, :headers = 12
    entry_count = 12;
    if (parsed.query_string != null) entry_count += 2;
    if (parsed.body != null) entry_count += 2;

    const entries = try allocator.alloc(Value, entry_count);
    var idx: usize = 0;

    // :server-port
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "server-port" });
    idx += 1;
    entries[idx] = Value.initInteger(server_port);
    idx += 1;

    // :server-name
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "server-name" });
    idx += 1;
    const sn = try allocator.dupe(u8, "localhost");
    entries[idx] = Value.initString(allocator, sn);
    idx += 1;

    // :remote-addr
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "remote-addr" });
    idx += 1;
    entries[idx] = Value.initString(allocator, addr_dup);
    idx += 1;

    // :uri
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "uri" });
    idx += 1;
    entries[idx] = Value.initString(allocator, uri_dup);
    idx += 1;

    // :request-method
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "request-method" });
    idx += 1;
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = method_str });
    idx += 1;

    // :headers
    entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "headers" });
    idx += 1;
    entries[idx] = Value.initMap(hdr_map);
    idx += 1;

    // :query-string (optional)
    if (parsed.query_string) |qs| {
        entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "query-string" });
        idx += 1;
        const qs_dup = try allocator.dupe(u8, qs);
        entries[idx] = Value.initString(allocator, qs_dup);
        idx += 1;
    }

    // :body (optional)
    if (parsed.body) |body| {
        entries[idx] = Value.initKeyword(allocator, .{ .ns = null, .name = "body" });
        idx += 1;
        const body_dup = try allocator.dupe(u8, body);
        entries[idx] = Value.initString(allocator, body_dup);
        idx += 1;
    }

    const req_map = try allocator.create(PersistentArrayMap);
    req_map.* = .{ .entries = entries[0..idx] };
    return Value.initMap(req_map);
}

// ============================================================
// Ring response formatting — currently unused (server runtime is stubbed).
// Kept compiling against std.Io.Writer so it can be wired up once the
// std.Io.net migration is implemented in a follow-up task.
// ============================================================

fn sendRingResponseToBuffer(buf: []u8, allocator: Allocator, response: Value) []const u8 {
    // Extract :status, :headers, :body from response map
    var status: i64 = 200;
    var body: []const u8 = "";
    var resp_headers: ?*const PersistentArrayMap = null;

    if (response.tag() == .map) {
        const m = response.asMap();
        for (0..m.entries.len / 2) |i| {
            const k = m.entries[i * 2];
            const v = m.entries[i * 2 + 1];
            if (k.tag() == .keyword) {
                const name = k.asKeyword().name;
                if (std.mem.eql(u8, name, "status")) {
                    if (v.tag() == .integer) status = v.asInteger();
                } else if (std.mem.eql(u8, name, "body")) {
                    if (v.tag() == .string) body = v.asString();
                } else if (std.mem.eql(u8, name, "headers")) {
                    if (v.tag() == .map) resp_headers = v.asMap();
                }
            }
        }
    }

    // Format HTTP response into the caller-provided buffer.
    _ = allocator;
    var w: std.Io.Writer = .fixed(buf);

    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, statusText(status) }) catch return w.buffered();

    var has_content_type = false;
    var has_content_length = false;
    if (resp_headers) |hdrs| {
        for (0..hdrs.entries.len / 2) |i| {
            const k = hdrs.entries[i * 2];
            const v = hdrs.entries[i * 2 + 1];
            const hdr_name = if (k.tag() == .string) k.asString() else if (k.tag() == .keyword) k.asKeyword().name else continue;
            const hdr_val = if (v.tag() == .string) v.asString() else continue;
            w.print("{s}: {s}\r\n", .{ hdr_name, hdr_val }) catch return w.buffered();
            if (std.ascii.eqlIgnoreCase(hdr_name, "content-type")) has_content_type = true;
            if (std.ascii.eqlIgnoreCase(hdr_name, "content-length")) has_content_length = true;
        }
    }
    if (!has_content_type) w.print("Content-Type: text/plain; charset=utf-8\r\n", .{}) catch return w.buffered();
    if (!has_content_length) w.print("Content-Length: {d}\r\n", .{body.len}) catch return w.buffered();
    w.print("Connection: close\r\n\r\n", .{}) catch return w.buffered();
    w.writeAll(body) catch return w.buffered();
    return w.buffered();
}

fn statusText(code: i64) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

// ============================================================
// HTTP client — temporarily disabled while std.http.Client migrates to the
// std.Io interface (Client now requires an `.io` field). Tracked as a
// Phase 7 follow-up F## item.
// ============================================================

fn httpRequestStub(args: []const Value) anyerror!Value {
    if (args.len < 1) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to http request", .{args.len});
    return err_mod.setError(.{
        .kind = .internal_error,
        .phase = .eval,
        .message = "http client (get/post/put/delete) is temporarily disabled while the std.http.Client → std.Io migration is in progress",
    });
}

pub fn getFn(_: Allocator, args: []const Value) anyerror!Value {
    return httpRequestStub(args);
}

pub fn postFn(_: Allocator, args: []const Value) anyerror!Value {
    return httpRequestStub(args);
}

pub fn putFn(_: Allocator, args: []const Value) anyerror!Value {
    return httpRequestStub(args);
}

pub fn deleteFn(_: Allocator, args: []const Value) anyerror!Value {
    return httpRequestStub(args);
}

// ============================================================
// Builtin definitions
// ============================================================

/// (set-handler! f)
/// Updates the handler function for the running HTTP server.
/// Enables live reload: redefine handler, then call set-handler! to apply.
pub fn setHandlerFn(_: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 1) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to set-handler!", .{args.len});
    const new_handler = args[0];
    switch (new_handler.tag()) {
        .builtin_fn, .fn_val => {},
        else => return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "set-handler!: argument must be a function" }),
    }
    const env = dispatch.macro_eval_env orelse return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "set-handler!: no evaluation environment" });
    if (env.findNamespace("cljw.http")) |ns| {
        if (ns.resolve("__handler")) |v| {
            v.bindRoot(new_handler);
        }
    }
    return Value.nil_val;
}

pub const builtins = [_]BuiltinDef{
    .{
        .name = "run-server",
        .func = &runServerFn,
        .doc = "Starts an HTTP server with the given Ring-compatible handler function. Options: {:port N}. Blocks until server is stopped.",
        .arglists = "([handler opts])",
        .added = "cljw",
    },
    .{
        .name = "get",
        .func = &getFn,
        .doc = "Performs an HTTP GET request. Returns {:status N :body \"...\"}.",
        .arglists = "([url] [url opts])",
        .added = "cljw",
    },
    .{
        .name = "post",
        .func = &postFn,
        .doc = "Performs an HTTP POST request. Returns {:status N :body \"...\"}.",
        .arglists = "([url opts])",
        .added = "cljw",
    },
    .{
        .name = "put",
        .func = &putFn,
        .doc = "Performs an HTTP PUT request. Returns {:status N :body \"...\"}.",
        .arglists = "([url opts])",
        .added = "cljw",
    },
    .{
        .name = "delete",
        .func = &deleteFn,
        .doc = "Performs an HTTP DELETE request. Returns {:status N :body \"...\"}.",
        .arglists = "([url] [url opts])",
        .added = "cljw",
    },
    .{
        .name = "set-handler!",
        .func = &setHandlerFn,
        .doc = "Updates the handler function for the running HTTP server. Enables live reload.",
        .arglists = "([handler])",
        .added = "cljw",
    },
};

// ============================================================
// Tests
// ============================================================

test "parseHttpRequest basic GET" {
    const raw = "GET /hello?name=world HTTP/1.1\r\nHost: localhost:8080\r\nAccept: text/plain\r\n\r\n";
    const parsed = parseHttpRequest(raw) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/hello", parsed.uri);
    try std.testing.expectEqualStrings("name=world", parsed.query_string.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.header_count);
    try std.testing.expectEqualStrings("Host", parsed.headers[0].name);
    try std.testing.expectEqualStrings("localhost:8080", parsed.headers[0].value);
}

test "parseHttpRequest POST with body" {
    const raw = "POST /api/data HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"key\":\"val\"}";
    const parsed = parseHttpRequest(raw) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("POST", parsed.method);
    try std.testing.expectEqualStrings("/api/data", parsed.uri);
    try std.testing.expect(parsed.query_string == null);
    try std.testing.expectEqual(@as(usize, 2), parsed.header_count);
    try std.testing.expectEqualStrings("{\"key\":\"val\"}", parsed.body.?);
}

test "parseHttpRequest minimal" {
    const raw = "GET / HTTP/1.1\r\n\r\n";
    const parsed = parseHttpRequest(raw) orelse return error.ParseFailed;
    try std.testing.expectEqualStrings("GET", parsed.method);
    try std.testing.expectEqualStrings("/", parsed.uri);
    try std.testing.expect(parsed.query_string == null);
    try std.testing.expect(parsed.body == null);
}

test "statusText" {
    try std.testing.expectEqualStrings("OK", statusText(200));
    try std.testing.expectEqualStrings("Not Found", statusText(404));
    try std.testing.expectEqualStrings("Internal Server Error", statusText(500));
}
