// SPDX-License-Identifier: EPL-2.0
//! cljw.http.client — outbound HTTP(S) via Zig 0.16 `std.http.Client` (TLS
//! bundled; system root certificates auto-rescanned on the first HTTPS request
//! because `Client.now` is null). Resolves D-257 (the client was a stub).
//!
//! Surface: `(cljw.http.client/get  url)` / `(… url opts)`
//!          `(cljw.http.client/post url opts)` / `put` / `delete`
//!   opts = `{:headers {"k" "v" …} :body "…"}`
//!   → a Ring-style response map `{:status <int> :body "<string>"}`.
//! Every failure (bad URL/opts, connect/TLS/DNS/protocol) is a CATCHABLE cljw
//! exception, never a process crash.
//!
//! F-006: the engine is handed `rt.gpa` + `rt.io` (never a global) so the TLS /
//! connection machinery uses the layer-1 allocator + the injected io context.
//!
//! Backend: impl-only
//! Impl deps: none
//! Clojure peer: cljw.http.client/{get,post,put,delete}
const std = @import("std");
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const Value = @import("../../value/value.zig").Value;
const error_catalog = @import("../../error/catalog.zig");
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const string_mod = @import("../../collection/string.zig");
const map_mod = @import("../../collection/map.zig");
const keyword_mod = @import("../../keyword.zig");

/// Shared request path for every method. `args[0]` is the URL string; `args[1]`
/// (optional) is an opts map (`:headers`, `:body`).
fn doRequest(rt: *Runtime, method: std.http.Method, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArityRange("cljw.http.client", args, 1, 2, loc);
    if (!args[0].isString())
        return error_catalog.raise(.http_url_invalid, loc, .{});
    const url = string_mod.asString(args[0]);

    // Arena for request-scoped scratch (the extra-headers slice must outlive the
    // fetch; string slices point into GC strings, valid for the synchronous call).
    var arena_state = std.heap.ArenaAllocator.init(rt.gpa);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    var payload: ?[]const u8 = null;
    var extra_headers: []const std.http.Header = &.{};

    if (args.len == 2) {
        const m = args[1];
        const mt = m.tag();
        if (mt != .array_map and mt != .hash_map)
            return error_catalog.raise(.http_opts_invalid, loc, .{ .detail = "the options argument must be a map" });

        const body_v = map_mod.get(m, try keyword_mod.intern(rt, null, "body")) catch Value.nil_val;
        if (!body_v.isNil()) {
            if (!body_v.isString())
                return error_catalog.raise(.http_opts_invalid, loc, .{ .detail = "the :body option must be a string" });
            payload = string_mod.asString(body_v);
        }

        const hdr_v = map_mod.get(m, try keyword_mod.intern(rt, null, "headers")) catch Value.nil_val;
        if (!hdr_v.isNil()) {
            if (hdr_v.tag() != .array_map)
                return error_catalog.raise(.http_opts_invalid, loc, .{ .detail = "the :headers option must be a map of string→string" });
            const am = hdr_v.decodePtr(*const map_mod.ArrayMap);
            var list: std.ArrayList(std.http.Header) = .empty;
            var i: u32 = 0;
            while (i < am.count) : (i += 1) {
                const k = am.entries[2 * i];
                const v = am.entries[2 * i + 1];
                if (!k.isString() or !v.isString())
                    return error_catalog.raise(.http_opts_invalid, loc, .{ .detail = "each :headers entry must be string→string" });
                try list.append(scratch, .{ .name = string_mod.asString(k), .value = string_mod.asString(v) });
            }
            extra_headers = list.items;
        }
    }

    var client: std.http.Client = .{ .allocator = rt.gpa, .io = rt.io };
    defer client.deinit();

    var body_buf: std.Io.Writer.Allocating = .init(rt.gpa);
    defer body_buf.deinit();

    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payload,
        .response_writer = &body_buf.writer,
        .extra_headers = extra_headers,
    }) catch return error_catalog.raise(.http_request_failed, loc, .{ .url = url });

    // {:status <int> :body "<captured body>"}
    var result = map_mod.empty();
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "status"), Value.initInteger(@intFromEnum(res.status)));
    result = try map_mod.assoc(rt, result, try keyword_mod.intern(rt, null, "body"), try string_mod.alloc(rt, body_buf.writer.buffered()));
    return result;
}

pub fn getFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return doRequest(rt, .GET, args, loc);
}
pub fn postFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return doRequest(rt, .POST, args, loc);
}
pub fn putFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return doRequest(rt, .PUT, args, loc);
}
pub fn deleteFn(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    return doRequest(rt, .DELETE, args, loc);
}
