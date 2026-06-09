// SPDX-License-Identifier: EPL-2.0
//! cljw.http.server — cljw's own HTTP server (ADR-0098), on Zig 0.16
//! `std.Io.net` + `std.http.Server`. Layer 0 (the cljw-original surface tree).
//!
//! Ring-style: `run-server` serves a blocking serial accept loop; each request
//! becomes a Ring request map `{:request-method :get :uri "/path" :query-string
//! "…" :headers {…} :body "…"}` passed to the handler (invoked via
//! `rt.vtable.callFn`), whose response map `{:status N :body "…"}` (or a bare
//! string body) is written back. Header names are lowercased (Ring); `:body` is
//! nil when the client declared none (read only on Content-Length/chunked,
//! capped at `max_body_bytes`).
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
const string_mod = @import("../../collection/string.zig");
const map_mod = @import("../../collection/map.zig");
const client = @import("client.zig");

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

/// Bind `0.0.0.0:port` and serve forever (blocking, serial), dispatching each
/// request through `handler` (a Ring `(fn [req] resp)`).
pub fn runServer(rt: *Runtime, env: *Env, handler: Value, port: u16, loc: SourceLocation) anyerror!Value {
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
        var stream = server.accept(io) catch continue;
        defer stream.close(io);
        var rbuf: [16384]u8 = undefined;
        var wbuf: [16384]u8 = undefined;
        var sr = stream.reader(io, &rbuf);
        var sw = stream.writer(io, &wbuf);
        var hs = std.http.Server.init(&sr.interface, &sw.interface);
        var req = hs.receiveHead() catch continue;

        // Build the Ring request map (cycle: method + uri; headers/body = D-257).
        const req_map = buildRequest(rt, &req, kw_method, kw_uri) catch {
            req.respond("Internal Server Error\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
            continue;
        };

        // Dispatch to the handler. A throwing handler → 500 (server stays up).
        const vtable = rt.vtable orelse
            return error_catalog.raiseInternal(loc, "cljw.http.server: runtime vtable not installed");
        const resp = vtable.callFn(rt, env, handler, &.{req_map}, loc) catch {
            req.respond("Internal Server Error\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
            continue;
        };

        // Render the response: a bare string is a 200 body; a map yields
        // {:status :body :headers}. `:headers` is a string→string map written
        // verbatim as response headers (Content-Type / Set-Cookie / etc.) — a
        // real web app on cljw needs to declare its content type and cookies
        // (D-257 follow-on). std.http writes no default content-type, so a
        // handler serving HTML must set `"content-type" "text/html; charset=utf-8"`.
        var status: std.http.Status = .ok;
        var body: []const u8 = "";
        // Response headers are tiny (≤8) and stay an array_map, so iterate its
        // flat entries directly rather than walk a HAMT. The string slices point
        // into the GC strings, valid for the synchronous respond() below.
        var header_buf: [16]std.http.Header = undefined;
        var n_headers: usize = 0;
        // SE-5: set false the moment a handler header name/value carries a control
        // byte (CRLF injection / std.http abort vector). A dirty response → 500.
        var headers_clean: bool = true;
        if (resp.tag() == .string) {
            body = string_mod.asString(resp);
        } else {
            const s = map_mod.get(resp, kw_status) catch Value.nil_val;
            // Validate the handler-supplied status to a real HTTP range BEFORE the
            // cast. A bare `@intCast(u10, …)` panics the whole server process on any
            // `:status` outside 0..1023 (the `respond` catch below does NOT cover a
            // cast panic here), and 0..1023 non-codes write a bogus status. Clamp to
            // the valid 100..599 range; anything else falls back to 500 rather than
            // crashing on handler (or request-derived) data.
            if (s.isInt()) {
                const code = s.asInteger();
                status = if (code >= 100 and code <= 599)
                    @enumFromInt(@as(u10, @intCast(code)))
                else
                    .internal_server_error;
            }
            const b = map_mod.get(resp, kw_body) catch Value.nil_val;
            if (b.tag() == .string) body = string_mod.asString(b);
            const h = map_mod.get(resp, kw_headers) catch Value.nil_val;
            if (h.tag() == .array_map) {
                const am = h.decodePtr(*const map_mod.ArrayMap);
                var i: u32 = 0;
                while (i < am.count and n_headers < header_buf.len) : (i += 1) {
                    const hk = am.entries[2 * i];
                    const hv = am.entries[2 * i + 1];
                    if (hk.tag() == .string and hv.tag() == .string) {
                        const nm = string_mod.asString(hk);
                        const vl = string_mod.asString(hv);
                        if (!headerFieldClean(nm) or !headerFieldClean(vl)) {
                            headers_clean = false;
                            break;
                        }
                        header_buf[n_headers] = .{ .name = nm, .value = vl };
                        n_headers += 1;
                    }
                }
            }
        }
        // SE-5: a control byte in any response header would split the response (or
        // abort std.http) — fail the response as a 500 rather than emit it.
        if (!headers_clean) {
            req.respond("Internal Server Error\n", .{ .status = .internal_server_error, .keep_alive = false }) catch {};
            continue;
        }
        req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = header_buf[0..n_headers] }) catch {};
    }
}

/// Cap on the request body cljw will buffer (DoS guard for the public edge
/// server). A larger body yields `:body nil` rather than an unbounded read.
const max_body_bytes = 8 * 1024 * 1024;

fn buildRequest(rt: *Runtime, req: *std.http.Server.Request, kw_method: Value, kw_uri: Value) !Value {
    // Everything sourced from the head (method / target / headers) is copied into
    // cljw Values FIRST: reading the body via readerExpectNone invalidates the
    // head's string memory, so the order here is load-bearing.
    const method_kw = try methodKeyword(rt, req.head.method);

    // Ring splits the path from the query: `:uri` is the path, `:query-string`
    // the part after `?` (nil when absent).
    const target = req.head.target;
    const q_idx = std.mem.findScalar(u8, target, '?');
    const path = if (q_idx) |i| target[0..i] else target;
    const uri_str = try string_mod.alloc(rt, path);
    const kw_query = try keyword_mod.intern(rt, null, "query-string");
    const query_val: Value = if (q_idx) |i| try string_mod.alloc(rt, target[i + 1 ..]) else Value.nil_val;

    // Headers → a cljw map {lowercased-name => value} (Ring lowercases names).
    const kw_headers = try keyword_mod.intern(rt, null, "headers");
    var headers = map_mod.empty();
    var hit = req.iterateHeaders();
    while (hit.next()) |h| {
        const lname = try std.ascii.allocLowerString(rt.gpa, h.name);
        defer rt.gpa.free(lname);
        const hk = try string_mod.alloc(rt, lname);
        const hv = try string_mod.alloc(rt, h.value);
        headers = try map_mod.assoc(rt, headers, hk, hv);
    }

    // Body → a cljw string (nil when there is none). Read ONLY when the client
    // declared a body (Content-Length or chunked); a body-less request with no
    // length would otherwise read the raw stream until EOF and block.
    const kw_body = try keyword_mod.intern(rt, null, "body");
    const has_body = req.head.content_length != null or req.head.transfer_encoding == .chunked;
    const body_val: Value = if (has_body) blk: {
        var body_buf: [16384]u8 = undefined;
        const reader = req.readerExpectContinue(&body_buf) catch break :blk Value.nil_val;
        const bytes = reader.allocRemaining(rt.gpa, std.Io.Limit.limited(max_body_bytes)) catch break :blk Value.nil_val;
        defer rt.gpa.free(bytes);
        break :blk if (bytes.len == 0) Value.nil_val else try string_mod.alloc(rt, bytes);
    } else Value.nil_val;

    var m = map_mod.empty();
    m = try map_mod.assoc(rt, m, kw_method, method_kw);
    m = try map_mod.assoc(rt, m, kw_uri, uri_str);
    m = try map_mod.assoc(rt, m, kw_query, query_val);
    m = try map_mod.assoc(rt, m, kw_headers, headers);
    m = try map_mod.assoc(rt, m, kw_body, body_val);
    return m;
}

// --- Clojure surface (cljw.http.server / cljw.http.client) ---
// These builtin fns live in the surface tree (runtime/cljw/**) per the ADR-0029
// D2 zone rule: lang/primitive/ may not import a surface, so the host fns + their
// ns registration live here and are wired via runtime/cljw/_host_api.zig.

/// `(run-server handler {:port N})` — Ring-style. `handler` is `(fn [req] resp)`;
/// `opts` carries `:port` (a bare integer port is also accepted). Blocking.
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
    return runServer(rt, env, handler, @intCast(port), loc);
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
