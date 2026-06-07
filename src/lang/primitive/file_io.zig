// SPDX-License-Identifier: EPL-2.0
//! File I/O primitives for the `rt/` namespace — Clojure-ns
//! surface.
//!
//! `slurp` and `spit` from clojure.core, restricted to the
//! file-path overload (the URL / Reader / Writer overloads arrive
//! when java.net.URL / java.io.Reader land).

const Value = @import("../../runtime/value/value.zig").Value;
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const env_mod = @import("../../runtime/env.zig");
const Env = env_mod.Env;
const error_mod = @import("../../runtime/error/info.zig");
const error_catalog = @import("../../runtime/error/catalog.zig");
const SourceLocation = error_mod.SourceLocation;
const dispatch = @import("../../runtime/dispatch.zig");
const file_io = @import("../../runtime/file_io.zig");
const string_collection = @import("../../runtime/collection/string.zig");

/// `(slurp path)` — read entire file as a UTF-8 String.
pub fn slurp(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("slurp", args, 1, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "slurp", .actual = @tagName(args[0].tag()) });
    }
    const path = string_collection.asString(args[0]);
    // Map the host I/O error to a catchable cljw exception (IOException Kind)
    // rather than letting the raw Zig error abort the program — a real app needs
    // `(try (slurp f) (catch Throwable _ default))` to work.
    const content = file_io.readAll(rt.io, rt.gpa, path) catch |e|
        return error_catalog.raise(.file_io_error, loc, .{ .op = "slurp", .path = path, .detail = @errorName(e) });
    defer rt.gpa.free(content);
    return try string_collection.alloc(rt, content);
}

/// `(spit path content)` — write `content` String to `path`,
/// replacing any existing file. Returns nil on success.
pub fn spit(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("spit", args, 2, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "spit", .actual = @tagName(args[0].tag()) });
    }
    if (args[1].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "spit", .actual = @tagName(args[1].tag()) });
    }
    const path = string_collection.asString(args[0]);
    const content = string_collection.asString(args[1]);
    file_io.writeAll(rt.io, path, content) catch |e|
        return error_catalog.raise(.file_io_error, loc, .{ .op = "spit", .path = path, .detail = @errorName(e) });
    return .nil_val;
}

// --- registration ---

const Entry = struct {
    name: []const u8,
    f: dispatch.BuiltinFn,
};

const ENTRIES = [_]Entry{
    .{ .name = "slurp", .f = &slurp },
    .{ .name = "spit", .f = &spit },
};

pub fn register(env: *Env, rt_ns: *env_mod.Namespace) !void {
    for (ENTRIES) |it| {
        _ = try env.intern(rt_ns, it.name, Value.initBuiltinFn(it.f), null);
    }
}
