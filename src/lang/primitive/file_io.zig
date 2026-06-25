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
const std = @import("std");
const keyword_mod = @import("../../runtime/keyword.zig");
const print_mod = @import("../../runtime/print.zig");
const host_instance = @import("../../runtime/host_instance.zig");

/// Coerce the file arg of `slurp`/`spit` to a path string: a `.string` directly,
/// or a `java.io.File` host instance (its path lives in `state[0]`, ADR-0126) —
/// the common `clojure.java.io/Coercions` case. Returns null for any other type.
/// R4-clean: identifies the File by descriptor identity via `rt.types` +
/// `host_instance` (neutral), NOT by importing the `runtime/java/io` surface
/// (same pattern as `core.zig` uriQ). The URL / URI / Reader / Writer / stream
/// Coercions arrive when those host types land (D-471).
fn coerceToPath(rt: *Runtime, v: Value) ?[]const u8 {
    if (v.tag() == .string) return string_collection.asString(v);
    if (v.tag() == .host_instance) {
        const td = rt.types.get("java.io.File") orelse return null;
        const hi = host_instance.asHostInstance(v);
        if (hi.descriptor == td) {
            const path_val: Value = @enumFromInt(hi.state[0]);
            return string_collection.asString(path_val);
        }
    }
    return null;
}

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
    const path = coerceToPath(rt, args[0]) orelse
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "slurp", .actual = @tagName(args[0].tag()) });
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
    // `(spit f content & options)` — clj's signature. clj coerces content via
    // `(str content)` (a non-string is rendered, a string passes through) and the
    // options are keyword/value pairs; cljw honours `:append` (truthy → append)
    // and accepts `:encoding` (UTF-8 always, a no-op) plus any further keys.
    try error_catalog.checkArityMin("spit", args, 2, loc);
    const path = coerceToPath(rt, args[0]) orelse
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "spit", .actual = @tagName(args[0].tag()) });
    var append_mode = false;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (args[i].tag() != .keyword) continue;
        if (std.mem.eql(u8, keyword_mod.asKeyword(args[i]).name, "append"))
            append_mode = args[i + 1].isTruthy();
    }
    // Coerce content via `(str content)`; a string is used directly (fast path).
    const content_owned: ?[]u8 = if (args[1].tag() == .string) null else blk: {
        var aw: std.Io.Writer.Allocating = .init(rt.gpa);
        defer aw.deinit();
        try print_mod.writeStrValue(rt, env, &aw.writer, args[1]);
        break :blk try rt.gpa.dupe(u8, aw.writer.buffered());
    };
    defer if (content_owned) |c| rt.gpa.free(c);
    const content = content_owned orelse string_collection.asString(args[1]);
    // SE-6: confine to the deploy FS jail (CLJW_FS_ROOT) and write the RESOLVED path.
    const jailed = file_io.jailResolve(rt.gpa, rt.fs_jail_root, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.FsJailEscape => return error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = "spit", .path = path }),
    };
    defer if (jailed) |j| rt.gpa.free(j);
    const open_path = jailed orelse path;
    if (append_mode)
        file_io.appendAll(rt.io, rt.gpa, open_path, content) catch |e|
            return raiseFileIoError("spit", path, e, loc)
    else
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
