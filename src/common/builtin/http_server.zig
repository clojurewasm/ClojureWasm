// cljw.http — HTTP server with Ring-compatible handler model.
//
// Provides a basic HTTP/1.1 server that calls a Clojure handler function
// for each request. The handler receives a Ring-style request map and
// returns a Ring-style response map.
//
// Usage from Clojure:
//   (require '[cljw.http :as http])
//   (defn handler [req] {:status 200 :body "Hello"})
//   (http/run-server handler {:port 8080})

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("../value.zig").Value;
const PersistentArrayMap = @import("../value.zig").PersistentArrayMap;
const collections = @import("../collections.zig");
const bootstrap = @import("../bootstrap.zig");
const var_mod = @import("../var.zig");
const BuiltinDef = var_mod.BuiltinDef;
const err_mod = @import("../error.zig");
const Env = @import("../env.zig").Env;

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

/// Module-level storage for background server (nREPL mode).
var bg_server: ?ServerState = null;

const ServerState = struct {
    env: *Env,
    handler: Value,
    alloc: Allocator,
    running: bool,
    mutex: std.Thread.Mutex,
    port: u16,
    listener: std.net.Server,
};

// ============================================================
// Builtins
// ============================================================

/// (run-server handler opts)
/// Starts an HTTP server that calls handler for each request.
/// handler: (fn [request-map]) -> response-map
/// opts: {:port N} (default 8080)
/// Blocks until the server is stopped (e.g. via SIGINT).
pub fn runServerFn(allocator: Allocator, args: []const Value) anyerror!Value {
    if (args.len < 2) return err_mod.setErrorFmt(.eval, .arity_error, .{}, "Wrong number of args ({d}) passed to run-server", .{args.len});

    // Skip during `cljw build` — allow require resolution without blocking.
    if (build_mode) return Value.nil_val;

    const handler = args[0];
    const opts = args[1];

    // Validate handler is callable
    switch (handler.tag()) {
        .builtin_fn, .fn_val => {},
        else => return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "run-server: first argument must be a function" }),
    }

    // Extract :port from opts map (default 8080)
    var port: u16 = 8080;
    if (opts.tag() == .map) {
        const m = opts.asMap();
        for (0..m.entries.len / 2) |i| {
            const k = m.entries[i * 2];
            const v = m.entries[i * 2 + 1];
            if (k.tag() == .keyword) {
                const name = k.asKeyword().name;
                if (std.mem.eql(u8, name, "port")) {
                    if (v.tag() == .integer) {
                        const p = v.asInteger();
                        if (p > 0 and p <= 65535) {
                            port = @intCast(p);
                        }
                    }
                }
            }
        }
    }

    // Root the handler by storing it in a hidden var (GC protection).
    const env = bootstrap.macro_eval_env orelse return err_mod.setError(.{ .kind = .type_error, .phase = .eval, .message = "run-server: no evaluation environment" });
    if (env.findNamespace("cljw.http")) |ns| {
        if (ns.resolve("__handler")) |v| {
            v.bindRoot(handler);
        }
    }

    // Bind TCP socket
    const address = std.net.Address.parseIp("0.0.0.0", port) catch {
        return err_mod.setErrorFmt(.eval, .value_error, .{}, "run-server: failed to parse address for port {d}", .{port});
    };
    const listener = address.listen(.{ .reuse_address = true }) catch {
        return err_mod.setErrorFmt(.eval, .value_error, .{}, "run-server: failed to listen on port {d}", .{port});
    };

    const actual_port = listener.listen_address.getPort();
    std.debug.print("cljw.http server running on port {d}\n", .{actual_port});

    if (background_mode) {
        // Non-blocking: store state in module-level static, run accept loop
        // in background thread. Used with --nrepl so nREPL can start after eval.
        bg_server = .{
            .env = env,
            .handler = handler,
            .alloc = allocator,
            .running = true,
            .mutex = .{},
            .port = actual_port,
            .listener = listener,
        };
        const thread = std.Thread.spawn(.{}, acceptLoop, .{&bg_server.?}) catch {
            return err_mod.setError(.{ .kind = .value_error, .phase = .eval, .message = "run-server: failed to spawn server thread" });
        };
        thread.detach();
        return Value.nil_val;
    }

    // Blocking mode: state on stack, accept loop runs in current thread.
    var state = ServerState{
        .env = env,
        .handler = handler,
        .alloc = allocator,
        .running = true,
        .mutex = .{},
        .port = actual_port,
        .listener = listener,
    };
    defer state.listener.deinit();

    acceptLoop(&state);
    return Value.nil_val;
}

// ============================================================
// Connection handler
// ============================================================

fn acceptLoop(state: *ServerState) void {
    while (state.running) {
        const conn = state.listener.accept() catch |e| {
            std.debug.print("accept error: {s}\n", .{@errorName(e)});
            continue;
        };
        const thread = std.Thread.spawn(.{}, handleConnection, .{ state, conn }) catch |e| {
            std.debug.print("thread spawn error: {s}\n", .{@errorName(e)});
            conn.stream.close();
            continue;
        };
        thread.detach();
    }
}

fn handleConnection(state: *ServerState, conn: std.net.Server.Connection) void {
    defer conn.stream.close();

    // Read HTTP request (up to 64KB)
    var buf: [65536]u8 = undefined;
    const n = conn.stream.read(&buf) catch return;
    if (n == 0) return;
    const request = buf[0..n];

    // Parse HTTP request
    const parsed = parseHttpRequest(request) orelse {
        sendErrorResponse(conn.stream, 400, "Bad Request");
        return;
    };

    // Build Ring request map and call handler under mutex.
    // Must set macro_eval_env for callFnVal (bytecodeCallBridge needs it).
    state.mutex.lock();
    defer state.mutex.unlock();

    // Set up eval context for this thread
    bootstrap.macro_eval_env = state.env;
    const predicates = @import("predicates.zig");
    predicates.current_env = state.env;

    const ring_req = buildRingRequest(state.alloc, parsed, state.port, conn.address) catch {
        sendErrorResponse(conn.stream, 500, "Internal Server Error");
        return;
    };

    // Call handler function
    const response = bootstrap.callFnVal(state.alloc, state.handler, &[1]Value{ring_req}) catch |e| {
        std.debug.print("handler error: {s}\n", .{@errorName(e)});
        sendErrorResponse(conn.stream, 500, "Internal Server Error");
        return;
    };

    // Format and send HTTP response
    sendRingResponse(conn.stream, state.alloc, response);
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
// Ring request map construction
// ============================================================

fn buildRingRequest(allocator: Allocator, parsed: ParsedRequest, server_port: u16, remote: std.net.Address) !Value {
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

    // Remote address string (IPv4 only for now)
    var addr_buf: [64]u8 = undefined;
    const ip_bytes = remote.in.sa.addr;
    const addr_str = std.fmt.bufPrint(&addr_buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(ip_bytes)),
        @as(u8, @truncate(ip_bytes >> 8)),
        @as(u8, @truncate(ip_bytes >> 16)),
        @as(u8, @truncate(ip_bytes >> 24)),
    }) catch "unknown";
    const addr_dup = try allocator.dupe(u8, addr_str);

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
// Ring response formatting
// ============================================================

fn sendRingResponse(stream: std.net.Stream, allocator: Allocator, response: Value) void {
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

    // Format HTTP response
    var buf: [65536]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // Status line
    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, statusText(status) }) catch return;

    // Headers from response map
    var has_content_type = false;
    var has_content_length = false;
    if (resp_headers) |hdrs| {
        for (0..hdrs.entries.len / 2) |i| {
            const k = hdrs.entries[i * 2];
            const v = hdrs.entries[i * 2 + 1];
            const hdr_name = if (k.tag() == .string) k.asString() else if (k.tag() == .keyword) k.asKeyword().name else continue;
            const hdr_val = if (v.tag() == .string) v.asString() else continue;
            w.print("{s}: {s}\r\n", .{ hdr_name, hdr_val }) catch return;
            if (std.ascii.eqlIgnoreCase(hdr_name, "content-type")) has_content_type = true;
            if (std.ascii.eqlIgnoreCase(hdr_name, "content-length")) has_content_length = true;
        }
    }

    // Default headers
    if (!has_content_type) {
        w.print("Content-Type: text/plain; charset=utf-8\r\n", .{}) catch return;
    }
    if (!has_content_length) {
        w.print("Content-Length: {d}\r\n", .{body.len}) catch return;
    }
    w.print("Connection: close\r\n", .{}) catch return;
    w.print("\r\n", .{}) catch return;

    // Send header + body
    const header_bytes = w.buffered();
    stream.writeAll(header_bytes) catch return;
    if (body.len > 0) {
        stream.writeAll(body) catch return;
    }
    _ = allocator;
}

fn sendErrorResponse(stream: std.net.Stream, status: u16, message: []const u8) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("HTTP/1.1 {d} {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        status, statusText(status), message.len, message,
    }) catch return;
    stream.writeAll(w.buffered()) catch {};
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
// Builtin definitions
// ============================================================

pub const builtins = [_]BuiltinDef{
    .{
        .name = "run-server",
        .func = &runServerFn,
        .doc = "Starts an HTTP server with the given Ring-compatible handler function. Options: {:port N}. Blocks until server is stopped.",
        .arglists = "([handler opts])",
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
