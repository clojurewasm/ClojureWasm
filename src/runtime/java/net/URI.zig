// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.net.URI` — a minimal string-backed host instance
//! (ADR-0106 host_instance container). Landed to unblock hiccup, whose
//! `hiccup.util` extends `ToString`/`ToURI` over `java.net.URI` and reads
//! `.getHost` / `.getPath` / `str`.
//!
//! Backend: impl-only
//! Impl deps: uri
//! Clojure peer: none.
//!
//! The instance is a `.host_instance` carrying this surface descriptor +
//! state[0]=pointer / state[1]=length of the gpa-duped URI string. host_instance
//! is a GC leaf (no Value in `state`), so a `.host_instance` tag finaliser frees
//! the duped bytes via the descriptor's `host_finalise` hook (Random's hook is
//! null — its state is pure u64). Accessors parse the string on demand
//! (`runtime/net/uri.zig`); the minimal parser covers scheme/host/path only,
//! and any accessor outside that scope is an explicit error, never a silent nil.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const string_collection = @import("../../collection/string.zig");
const uri = @import("../../net/uri.zig");

var uri_descriptor: ?*const type_descriptor.TypeDescriptor = null;

/// The gpa-duped URI string carried by a URI host instance.
fn uriString(recv: Value) []const u8 {
    const inst = host_instance.asHostInstance(recv);
    const ptr: [*]const u8 = @ptrFromInt(inst.state[0]);
    return ptr[0..inst.state[1]];
}

/// `(java.net.URI. "scheme://host/path")` — store the string verbatim; accessors
/// parse on demand. clj's `URI.` also validates RFC 3986 syntax (throwing
/// URISyntaxException); cljw's minimal surface accepts any string (the parse is
/// best-effort per component). A non-string arg is a loud type error.
fn initUri(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.net.URI.", args, 1, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.net.URI.", .actual = @tagName(args[0].tag()) });
    const s = string_collection.asString(args[0]);
    const owned = try rt.gc.infra.dupe(u8, s);
    const td = uri_descriptor orelse return error.NoVTable;
    return host_instance.alloc(rt, td, .{ @intFromPtr(owned.ptr), owned.len, 0, 0 });
}

/// `(.getHost u)` — the host, or nil for a URI with no `//authority`.
fn getHost(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getHost", args, 1, loc);
    const h = uri.host(uriString(args[0])) orelse return Value.nil_val;
    return string_collection.alloc(rt, h);
}

/// `(.getPath u)` — the path, or nil for an opaque URI (`scheme:body`).
fn getPath(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getPath", args, 1, loc);
    const p = uri.path(uriString(args[0])) orelse return Value.nil_val;
    return string_collection.alloc(rt, p);
}

/// `(str u)` / `(.toString u)` — the original URI string.
fn toString(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("toString", args, 1, loc);
    return string_collection.alloc(rt, uriString(args[0]));
}

/// `host_finalise` hook: free the gpa-duped URI bytes when the host instance is
/// swept (host_instance is a GC leaf; the descriptor routes the tag finaliser
/// here — see host_instance.zig).
fn finaliseState(infra: std.mem.Allocator, state: *[host_instance.STATE_WORDS]u64) void {
    const ptr: [*]u8 = @ptrFromInt(state[0]);
    infra.free(ptr[0..state[1]]);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initUri },
    // `(java.net.URI/create s)` — the static factory; same body as the ctor
    // (parse + wrap the string). The common idiom alongside `(URI. s)`.
    .{ .name = "create", .f = &initUri },
    .{ .name = "getHost", .f = &getHost },
    .{ .name = "getPath", .f = &getPath },
    .{ .name = "toString", .f = &toString },
};

fn initUriDescriptor(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    uri_descriptor = td;
    td.host_finalise = &finaliseState;
    const entries = try gpa.alloc(type_descriptor.TypeDescriptor.MethodEntry, METHODS.len);
    for (METHODS, 0..) |m, i| {
        entries[i] = .{
            .protocol_name = "",
            .method_name = try gpa.dupe(u8, m.name),
            .method_val = Value.initBuiltinFn(m.f),
        };
    }
    td.method_table = entries;
}

pub const ___HOST_EXTENSION: host_api.Extension = .{
    .cljw_ns = "cljw.java.net.URI",
    .descriptor = &descriptor,
    .init = &initUriDescriptor,
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.net.URI",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .parent = null,
    .meta = .nil_val,
};
