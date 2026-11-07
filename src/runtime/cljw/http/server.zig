// SPDX-License-Identifier: EPL-2.0
//! cljw.http.server — cljw's own HTTP server (ADR-0098), on Zig 0.16
//! `std.Io.net` + `std.http.Server`. Layer 0 (the cljw-original surface tree).
//!
//! Ring-style: `run-server` serves a blocking serial accept loop; each request
//! becomes a Ring request map `{:request-method :get :uri "/path" :query-string
//! "…" :headers {…} :body "…"}` passed to the handler (invoked via
//! `rt.vtable.callFn`), whose response map `{:status N :body "…"}` (or a bare
//! string body) is written back. A response `:body` may also be a primitive
//! byte-array (`byte-array`, e.g. from `wasm/mem-read-array`): its bytes are
//! copied verbatim. Header names are lowercased (Ring);
//! `:body` is nil when the client declared none (read only on
//! Content-Length/chunked, capped at `max_body_bytes`).
//!
//! Follow-ons (D-257 remainder): per-connection threading + a non-blocking stop
//! handle (so keep-alive can be re-enabled), and per-request GC rooting of the
//! freshly-built request map under auto-collect (today auto-collect is off, so
//! the build-then-immediately-call path is safe).
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.http.server/run-server
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_mod = @import("../../error/info.zig");
const SourceLocation = error_mod.SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const keyword_mod = @import("../../keyword.zig");
const safepoint = @import("../../concurrency/safepoint.zig");
const string_mod = @import("../../collection/string.zig");
const map_mod = @import("../../collection/map.zig");
const client = @import("client.zig");
const java_array = @import("../../collection/java_array.zig");

/// `:request-method` keyword for an HTTP method (lowercase, Ring convention).
fn methodKeyword(rt: *Runtime, m: std.http.Method) !Value {
    const name = switch (m) {
        .GET => "get",
        .HEAD => "head",
        .POST => "post",
        .PUT => "put",
        .DELETE => "delete",
        .OPTIONS => "options",
        .PATCH => "patch",
        .TRACE => "trace",
        .CONNECT => "connect",
    };
    return keyword_mod.intern(rt, null, name);
}

/// HTTP header field validation (SE-5). Reject any name/value byte that is an
/// ASCII control char (CR / LF / NUL / TAB / DEL, anything < 0x20 or 0x7F). A
/// CRLF in a header value reflected from request data would split the response
/// (header injection); worse, the current Zig `std.http` `respond` ABORTS the
/// process on a CRLF header value (an uncatchable panic, not an error). cljw
/// validates at its own boundary BEFORE `respond` rather than trusting an
/// unaudited, version-dependent stdlib invariant — a dirty header is treated as
/// a server error (500), never emitted and never crashes the server.
fn headerFieldClean(s: []const u8) bool {
    for (s) |b| {
        if (b < 0x20 or b == 0x7F) return false;
    }
    return true;
}

/// Default request-head read deadline in milliseconds (D-339 / SE-3). Ten
/// seconds is the same order as nginx's `client_header_timeout` and Go's
/// documented `ReadHeaderTimeout` examples: far longer than any legitimate
/// client needs to finish a request line + headers over a live connection,
/// far shorter than "forever".
pub const default_header_timeout_ms: i64 = 10_000;

/// Arm a receive deadline on an accepted connection (D-339 / SE-3).
///
/// The accept loop is serial by design, so a peer that opens a connection and
/// never finishes sending the request head blocks EVERY other client for as
/// long as the read blocks — and with no deadline that is forever, so a single
/// packet takes down a public deploy (the server binds 0.0.0.0). `SO_RCVTIMEO`
/// turns that unbounded wedge into a bounded one: the stalled read fails, the
/// loop drops the connection and serves the next client.
///
/// This bounds the wedge; it does not remove it. A serial server still handles
/// one connection at a time, so an attacker holding N connections still costs
/// N × timeout of throughput. Removing that needs per-connection concurrency,
/// which is a different change with GC-registration consequences (a handler
/// runs Clojure, so its thread must be a registered GC worker per ADR-0175) —
/// tracked separately as the D-257 threading follow-on, not smuggled in here.
///
/// Best-effort: a platform that rejects the option leaves the socket blocking
/// rather than failing the request. Nothing else in the loop depends on it.
fn armReceiveDeadline(handle: std.posix.socket_t, timeout_ms: i64) void {
    if (timeout_ms <= 0) return; // 0 / negative = caller opted out
    const tv: std.posix.timeval = .{
        .sec = @intCast(@divTrunc(timeout_ms, 1000)),
        .usec = @intCast(@rem(timeout_ms, 1000) * 1000),
    };
    std.posix.setsockopt(handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {
        // Best-effort by design — see the doc comment. No recovery to attempt
        // and no user-visible surface to report it on.
    };
}

/// Bind `0.0.0.0:port` and serve forever (blocking, serial), dispatching each
/// request through `handler` (a Ring `(fn [req] resp)`). `header_timeout_ms`
/// bounds how long a connection may take to deliver its request head (D-339).
pub fn runServer(
    rt: *Runtime,
    env: *Env,
    handler: Value,
    port: u16,
    header_timeout_ms: i64,
    loc: SourceLocation,
) anyerror!Value {
    const io = rt.io;
    const kw_method = try keyword_mod.intern(rt, null, "request-method");
    const kw_uri = try keyword_mod.intern(rt, null, "uri");
    const kw_status = try keyword_mod.intern(rt, null, "status");
    const kw_body = try keyword_mod.intern(rt, null, "body");
    const kw_headers = try keyword_mod.intern(rt, null, "headers");

    var addr = std.Io.net.IpAddress.parse("0.0.0.0", port) catch
        return error_catalog.raiseInternal(loc, "cljw.http.server: invalid bind address");
    // reuse_address (SO_REUSEADDR): rebind the port while prior connections from a
    // just-stopped server linger in TIME_WAIT — otherwise a crash-then-restart (or
    // two back-to-back e2e servers on a fixed port) fails to bind for ~30-60s.
    var server = addr.listen(io, .{ .reuse_address = true }) catch
        return error_catalog.raiseInternal(loc, "cljw.http.server: listen/bind failed (port in use?)");

    while (true) {
        // Waits on the network run under safepoint.blocking, so a server started
        // in a `future` does not stall collections between requests.
        var stream = safepoint.blocking(std.Io.net.Server.accept, .{ &server, io }) catch continue;
        defer stream.close(io);
        // D-339: bound the request-head read BEFORE the first read on this
        // connection, so a peer that stalls mid-head cannot hold the serial
        // loop open indefinitely.
        armReceiveDeadline(stream.socket.handle, header_timeout_ms);
        var rbuf: [16384]u8 = undefined;
        var wbuf: [16384]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        var hs = std.http.Server.init(&sr.interface, &sw.interface);
        var req = safepoint.blocking(std.http.Server.receiveHead, .{&hs}) catch continue;

        // Build the Ring request map (cycle: method + uri; headers/body = D-257).
        const req_map = buildRequest(rt, &req, kw_method, kw_uri) catch {
            safepoint.blocking(respondBytes, .{ &req, ResponseBytes.server_error });
            continue;
        };

        // Dispatch to the handler. A throwing handler → 500 (server stays up).
        const vtable = rt.vtable orelse
            return error_catalog.raiseInternal(loc, "cljw.http.server: runtime vtable not installed");
        const resp = vtable.callFn(rt, env, handler, &.{req_map}, loc) catch {
            safepoint.blocking(respondBytes, .{ &req, ResponseBytes.server_error });
            continue;
        };

        // Copy the response into arena bytes, then write them. The write can
        // block on a slow peer, so it runs under safepoint.blocking; `resp` is
        // an unrooted local, so nothing it owns may be referenced while this
        // worker counts as parked.
        var resp_arena = std.heap.ArenaAllocator.init(rt.gpa);
        defer resp_arena.deinit();
        const rb = collectResponse(resp_arena.allocator(), resp, kw_status, kw_body, kw_headers) catch
            ResponseBytes.server_error;
        safepoint.blocking(respondBytes, .{ &req, rb });
    }
}

/// A response as plain bytes owned by a scratch arena: the collect stratum of
/// the write, as `RequestBytes` is of the read.
const ResponseBytes = struct {
    status: std.http.Status,
    body: []const u8,
    headers: []const std.http.Header,

    const server_error: ResponseBytes = .{
        .status = .internal_server_error,
        .body = "Internal Server Error\n",
        .headers = &.{},
    };
};

/// Render the handler's response Value into `arena` bytes. A bare string is a
/// 200 body; a map yields {:status :body :headers}. `:headers` is a
/// string→string map written verbatim as response headers (Content-Type /
/// Set-Cookie / etc.); std.http writes no default content-type, so a handler
/// serving HTML must set `"content-type" "text/html; charset=utf-8"`.
fn collectResponse(arena: std.mem.Allocator, resp: Value, kw_status: Value, kw_body: Value, kw_headers: Value) !ResponseBytes {
    if (resp.tag() == .string)
        return .{ .status = .ok, .body = try arena.dupe(u8, string_mod.asString(resp)), .headers = &.{} };

    var status: std.http.Status = .ok;
    const s = map_mod.get(resp, kw_status) catch Value.nil_val;
    // Validate the handler-supplied status to a real HTTP range BEFORE the
    // cast. A bare `@intCast(u10, …)` panics the whole server process on any
    // `:status` outside 0..1023, and 0..1023 non-codes write a bogus status.
    // Clamp to 100..599; anything else falls back to 500.
    if (s.isInt()) {
        const code = s.asInteger();
        status = if (code >= 100 and code <= 599)
            @enumFromInt(@as(u10, @intCast(code)))
        else
            .internal_server_error;
    }
    var body: []const u8 = "";
    const b = map_mod.get(resp, kw_body) catch Value.nil_val;
    if (b.tag() == .string) body = try arena.dupe(u8, string_mod.asString(b));
    // byte-array body: verbatim copy
    if (b.tag() == .array and java_array.isKind(b, .byte)) body = try arena.dupe(u8, java_array.asArray(b).bytes());

    var headers: std.ArrayList(std.http.Header) = .empty;
    const h = map_mod.get(resp, kw_headers) catch Value.nil_val;
    if (h.tag() == .array_map or h.tag() == .hash_map) {
        // Iterate via the generic `forEachEntry`: a 9+-entry :headers map
        // promotes to hash_map (Discussion #12 bug class). At most 16 headers.
        // SE-5: a control byte in any name or value (CRLF injection / std.http
        // abort vector) fails the whole response as a 500.
        const HdrCollect = struct {
            arena: std.mem.Allocator,
            list: *std.ArrayList(std.http.Header),
            clean: *bool,
            fn put(c: *@This(), hk: Value, hv: Value) anyerror!void {
                if (!c.clean.* or c.list.items.len >= 16) return;
                if (hk.tag() != .string or hv.tag() != .string) return;
                const nm = string_mod.asString(hk);
                const vl = string_mod.asString(hv);
                if (!headerFieldClean(nm) or !headerFieldClean(vl)) {
                    c.clean.* = false;
                    return;
                }
                try c.list.append(c.arena, .{ .name = try c.arena.dupe(u8, nm), .value = try c.arena.dupe(u8, vl) });
            }
        };
        var clean = true;
        var hctx: HdrCollect = .{ .arena = arena, .list = &headers, .clean = &clean };
        try map_mod.forEachEntry(h, &hctx, HdrCollect.put);
        if (!clean) return ResponseBytes.server_error;
    }
    return .{ .status = status, .body = body, .headers = headers.items };
}

/// Write `rb` to the peer. It blocks on the network and touches no GC memory,
/// so callers run it under `safepoint.blocking`. A failed write is dropped:
/// the connection closes either way.
fn respondBytes(req: *std.http.Server.Request, rb: ResponseBytes) void {
    req.respond(rb.body, .{ .status = rb.status, .keep_alive = false, .extra_headers = rb.headers }) catch {};
}

/// Cap on the request body cljw will buffer (DoS guard for the public edge
/// server). A larger body yields `:body nil` rather than an unbounded read.
const max_body_bytes = 8 * 1024 * 1024;

/// A request as plain bytes owned by a scratch arena. Nothing here is a GC
/// Value, so reading the body cannot leave a half-built map for a collection.
const RequestBytes = struct {
    method: std.http.Method,
    target: []const u8,
    /// `{lowercased-name, value}` pairs (Ring lowercases names).
    headers: []const [2][]const u8,
    body: ?[]const u8,
};

/// Copy the head, then read the body. The head is copied FIRST: reading the
/// body via readerExpectContinue invalidates the head's string memory.
fn collectRequest(arena: std.mem.Allocator, req: *std.http.Server.Request) !RequestBytes {
    const target = try arena.dupe(u8, req.head.target);
    var headers: std.ArrayList([2][]const u8) = .empty;
    var hit = req.iterateHeaders();
    while (hit.next()) |h|
        try headers.append(arena, .{ try std.ascii.allocLowerString(arena, h.name), try arena.dupe(u8, h.value) });

    // Read ONLY when the client declared a body (Content-Length or chunked); a
    // body-less request with no length would otherwise read to EOF and block.
    const has_body = req.head.content_length != null or req.head.transfer_encoding == .chunked;
    const body: ?[]const u8 = if (has_body) blk: {
        var body_buf: [16384]u8 = undefined;
        const reader = req.readerExpectContinue(&body_buf) catch break :blk null;
        const bytes = reader.allocRemaining(arena, std.Io.Limit.limited(max_body_bytes)) catch break :blk null;
        break :blk if (bytes.len == 0) null else bytes;
    } else null;
    return .{ .method = req.head.method, .target = target, .headers = headers.items, .body = body };
}

/// The Ring request map for `rb`. Built in a fabrication region: every
/// intermediate is an unrooted local until the map is returned.
fn requestValue(rt: *Runtime, rb: RequestBytes, kw_method: Value, kw_uri: Value) !Value {
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();

    // Ring splits the path from the query: `:uri` is the path, `:query-string`
    // the part after `?` (nil when absent).
    const q_idx = std.mem.findScalar(u8, rb.target, '?');
    const path = if (q_idx) |i| rb.target[0..i] else rb.target;
    const query_val: Value = if (q_idx) |i| try string_mod.alloc(rt, rb.target[i + 1 ..]) else Value.nil_val;

    var headers = map_mod.empty();
    for (rb.headers) |h|
        headers = try map_mod.assoc(rt, headers, try string_mod.alloc(rt, h[0]), try string_mod.alloc(rt, h[1]));

    const body_val: Value = if (rb.body) |b| try string_mod.alloc(rt, b) else Value.nil_val;

    var m = map_mod.empty();
    m = try map_mod.assoc(rt, m, kw_method, try methodKeyword(rt, rb.method));
    m = try map_mod.assoc(rt, m, kw_uri, try string_mod.alloc(rt, path));
    m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "query-string"), query_val);
    m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "headers"), headers);
    m = try map_mod.assoc(rt, m, try keyword_mod.intern(rt, null, "body"), body_val);
    return m;
}

fn buildRequest(rt: *Runtime, req: *std.http.Server.Request, kw_method: Value, kw_uri: Value) !Value {
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const rb = try safepoint.blocking(collectRequest, .{ arena_state.allocator(), req });
    return requestValue(rt, rb, kw_method, kw_uri);
}

// --- Clojure surface (cljw.http.server / cljw.http.client) ---
// These builtin fns live in the surface tree (runtime/cljw/**) per the ADR-0029
// D2 zone rule: lang/primitive/ may not import a surface, so the host fns + their
// ns registration live here and are wired via runtime/cljw/_host_api.zig.

/// `(run-server handler {:port N :header-timeout-ms MS})` — Ring-style.
/// `handler` is `(fn [req] resp)`; `opts` carries `:port` (a bare integer port
/// is also accepted) and the optional `:header-timeout-ms` (D-339; default
/// `default_header_timeout_ms`, `0` disables the deadline). Blocking.
pub fn runServerFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("run-server", args, 2, loc);
    const handler = args[0];
    const opts = args[1];
    const port: i64 = blk: {
        if (opts.isInt()) break :blk opts.asInteger();
        const kw_port = try keyword_mod.intern(rt, null, "port");
        const p = map_mod.get(opts, kw_port) catch Value.nil_val;
        if (!p.isInt())
            return error_catalog.raiseInternal(loc, "run-server: opts map needs an integer :port");
        break :blk p.asInteger();
    };
    if (port < 1 or port > 65535)
        return error_catalog.raiseInternal(loc, "run-server: port out of range (1..65535)");
    const header_timeout_ms: i64 = blk: {
        if (opts.isInt()) break :blk default_header_timeout_ms;
        const kw_ht = try keyword_mod.intern(rt, null, "header-timeout-ms");
        const t = map_mod.get(opts, kw_ht) catch Value.nil_val;
        if (t.isNil()) break :blk default_header_timeout_ms;
        if (!t.isInt())
            return error_catalog.raiseInternal(loc, "run-server: :header-timeout-ms must be an integer (milliseconds; 0 disables)");
        break :blk t.asInteger();
    };
    return runServer(rt, env, handler, @intCast(port), header_timeout_ms, loc);
}

/// Create the `cljw.http.server` / `cljw.http.client` host namespaces. Called by
/// `runtime/cljw/_host_api.zig::installAll`. The client fns live in `client.zig`
/// (D-257 discharged: a real outbound HTTP(S) client via std.http.Client).
pub fn register(env: *Env) !void {
    const srv = try env.findOrCreateNs("cljw.http.server");
    _ = try env.intern(srv, "run-server", Value.initBuiltinFn(&runServerFn), null);

    const cli = try env.findOrCreateNs("cljw.http.client");
    _ = try env.intern(cli, "get", Value.initBuiltinFn(&client.getFn), null);
    _ = try env.intern(cli, "post", Value.initBuiltinFn(&client.postFn), null);
    _ = try env.intern(cli, "put", Value.initBuiltinFn(&client.putFn), null);
    _ = try env.intern(cli, "delete", Value.initBuiltinFn(&client.deleteFn), null);
}
