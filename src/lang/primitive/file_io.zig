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

/// Map a host I/O error from `slurp`/`spit` to a catchable cljw exception.
/// A missing path (or missing parent directory) routes to the leaf
/// `FileNotFoundException` (clj parity, D-321); every other I/O failure stays
/// the generic `IOException`. Single source so both surfaces classify alike.
fn raiseFileIoError(op: []const u8, path: []const u8, e: anyerror, loc: SourceLocation) anyerror {
    if (e == error.FileNotFound)
        return error_catalog.raise(.file_not_found_error, loc, .{ .op = op, .path = path });
    return error_catalog.raise(.file_io_error, loc, .{ .op = op, .path = path, .detail = @errorName(e) });
}

/// `(slurp path)` — read entire file as a UTF-8 String.
pub fn slurp(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("slurp", args, 1, loc);
    if (args[0].tag() != .string) {
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "slurp", .actual = @tagName(args[0].tag()) });
    }
    const path = string_collection.asString(args[0]);
    // SE-6: confine to the deploy FS jail (CLJW_FS_ROOT) and open the RESOLVED
    // path (so the file read is the one that was containment-checked).
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "slurp", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;
    // Map the host I/O error to a catchable cljw exception (FileNotFoundException
    // for a missing file, IOException otherwise) rather than letting the raw Zig
    // error abort the program — a real app needs `(try (slurp f) (catch Throwable
    // _ default))` to work.
    const content = file_io.readAll(rt.io, rt.gpa, open_path) catch |e|
        return raiseFileIoError("slurp", path, e, loc);
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
    // SE-6: confine to the deploy FS jail (CLJW_FS_ROOT) and write the RESOLVED path.
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "spit", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;
    file_io.writeAll(rt.io, open_path, content) catch |e|
        return raiseFileIoError("spit", path, e, loc);
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
