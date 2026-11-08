// SPDX-License-Identifier: EPL-2.0
//! Java surface for `java.io.File` — a path-valued native instance (ADR-0126,
//! built on the ADR-0106 `host_instance` container, mirroring
//! `runtime/java/util/Random.zig`).
//!
//! Backend: impl-only
//! Impl deps: file_io
//! Clojure peer: clojure.java.io (file / as-file / delete-file / make-parents)
//!
//! state[0] holds the path as a cljw string `Value`, so the descriptor
//! registers a `host_trace` hook to mark it across a collect. The instance is
//! immutable (the path is fixed at construction); query/mutation methods derive
//! everything from that path. FS-touching methods route the path through the
//! deploy FS-jail (`file_io.jailResolve`, ADR-0123) and open the resolved path;
//! pure path methods (getName / getParent / isAbsolute) never touch the FS and
//! skip the jail.
//!
//! cljw-style divergences (no-JVM, ADR-0059 / ADR-0126):
//!   - `.list` / `.listFiles` return a cljw vector (not a JVM `String[]`/`File[]`
//!     array) — the Java array tower is Phase-16 deferred (D-051); a vector is
//!     `seq`/`count`/`sort`-able, matching every realistic call site.
//!   - `.getCanonicalPath` resolves `.`/`..` lexically but NOT symlinks (the
//!     std.Io handle model has no realpath; D-357). `.getAbsolutePath` /
//!     `.getCanonicalPath` resolve a relative path against the process cwd via
//!     `std.process.currentPathAlloc`.

const std = @import("std");
const host_api = @import("../_host_api.zig");
const type_descriptor = @import("../../type_descriptor.zig");
const Value = @import("../../value/value.zig").Value;
const Runtime = @import("../../runtime.zig").Runtime;
const Env = @import("../../env.zig").Env;
const SourceLocation = @import("../../error/info.zig").SourceLocation;
const error_catalog = @import("../../error/catalog.zig");
const host_instance = @import("../../host_instance.zig");
const file_io = @import("../../file_io.zig");
const string_mod = @import("../../collection/string.zig");
const vector_mod = @import("../../collection/vector.zig");
const java_array = @import("../../collection/java_array.zig");
const clock = @import("../../clock.zig");
const compare_mod = @import("../../compare.zig");
const process_env = @import("../../process_env.zig");
const mark_sweep = @import("../../gc/mark_sweep.zig");
const gc_heap_mod = @import("../../gc/gc_heap.zig");

const path = std.Io.Dir.path;

/// The live rt.types descriptor (set in `initFile`), embedded into every File
/// HostInstance so `<init>` and instance-method dispatch share it.
var file_descriptor: ?*const type_descriptor.TypeDescriptor = null;

fn pathValOf(recv: Value) Value {
    return @enumFromInt(host_instance.asHostInstance(recv).state[0]);
}
fn pathOf(recv: Value) []const u8 {
    return string_mod.asString(pathValOf(recv));
}
fn isFileInstance(v: Value) bool {
    return v.tag() == .host_instance and host_instance.asHostInstance(v).descriptor == file_descriptor;
}

/// Mint a File instance carrying the string `path_val` (already a cljw string).
fn allocFile(rt: *Runtime, path_val: Value) !Value {
    const td = file_descriptor orelse return error.NoVTable;
    // Every caller hands a freshly allocated, still unrooted path string. The
    // HostInstance alloc below can trigger a collection (every alloc does under
    // CLJW_GC_TORTURE_ALLOC=1) that swept that string, leaving the File with a
    // dangling path (measured: `(.getPath (File. "test/clj/suites"))` -> "/tmp",
    // `.isDirectory` false). No collection inside the region keeps it alive.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    return host_instance.alloc(rt, td, .{ @intFromEnum(path_val), 0, 0, 0 });
}

/// Java `UnixFileSystem.normalize`, applied at construction so the STORED path
/// (returned verbatim by `getPath`/`toString`, and the base for every other
/// method) matches the JVM: collapse runs of `/` to a single `/`, then strip a
/// trailing `/` unless the whole path is `/`. Does NOT resolve `.`/`..` (that is
/// `getCanonicalPath`'s job). `(File. "/a//b/c/")` → stored "/a/b/c" (D-431).
fn normalizePath(rt: *Runtime, raw: []const u8) !Value {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(rt.gpa);
    var prev_slash = false;
    for (raw) |c| {
        if (c == '/') {
            if (!prev_slash) try buf.append(rt.gpa, '/');
            prev_slash = true;
        } else {
            try buf.append(rt.gpa, c);
            prev_slash = false;
        }
    }
    if (buf.items.len > 1 and buf.items[buf.items.len - 1] == '/') _ = buf.pop();
    return string_mod.alloc(rt, buf.items);
}

/// Resolve `p` under the deploy FS-jail; null when the jail is OFF (open the
/// original `p`). Maps a jail breach to a catchable `fs_jail_escape`.
fn jailed(rt: *Runtime, p: []const u8, fn_name: []const u8, loc: SourceLocation) anyerror!?[]u8 {
    return file_io.jailResolve(rt.gpa, rt.fs_jail_root, p) catch |e| switch (e) {
        error.OutOfMemory => e,
        error.FsJailEscape => error_catalog.raise(.fs_jail_escape, loc, .{ .fn_name = fn_name, .path = p }),
    };
}

// --- constructor ---

/// `(java.io.File. path)` / `(java.io.File. parent child)`. `parent` is a String
/// or a File; `child` is a String, joined with the platform separator.
fn initFileInstance(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    if (args.len == 1) {
        if (args[0].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.io.File.", .actual = @tagName(args[0].tag()) });
        return allocFile(rt, try normalizePath(rt, string_mod.asString(args[0])));
    }
    if (args.len == 2) {
        const parent_path = if (args[0].tag() == .string)
            string_mod.asString(args[0])
        else if (isFileInstance(args[0]))
            pathOf(args[0])
        else
            return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = "java.io.File.", .expected = "a String or File parent", .actual = @tagName(args[0].tag()) });
        if (args[1].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.io.File.", .actual = @tagName(args[1].tag()) });
        const joined = try path.join(rt.gpa, &.{ parent_path, string_mod.asString(args[1]) });
        defer rt.gpa.free(joined);
        return allocFile(rt, try normalizePath(rt, joined));
    }
    return error_catalog.raise(.arity_not_expected, loc, .{ .got = args.len, .fn_name = "java.io.File.", .expected = 1 });
}

// --- pure path methods (no FS touch, no jail) ---

fn getName(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getName", args, 1, loc);
    return string_mod.alloc(rt, path.basenamePosix(pathOf(args[0])));
}

fn getPath(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("getPath", args, 1, loc);
    return pathValOf(args[0]);
}

/// `(.compareTo f g)`: JVM `UnixFileSystem.compare`: the `String.compareTo`
/// of the two paths. Makes File Comparable, so `compare` / `sort` / sorted
/// collections order Files by path.
fn compareTo(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("compareTo", args, 2, loc);
    if (!isFileInstance(args[1]))
        return error_catalog.raise(.type_arg_invalid, loc, .{ .fn_name = ".compareTo", .expected = "File", .actual = @tagName(args[1].tag()) });
    return Value.initInteger(compare_mod.javaCompareTo(pathValOf(args[0]), pathValOf(args[1])).?);
}

fn getParent(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getParent", args, 1, loc);
    const parent = path.dirnamePosix(pathOf(args[0])) orelse return Value.nil_val;
    return string_mod.alloc(rt, parent);
}

fn getParentFile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getParentFile", args, 1, loc);
    const parent = path.dirnamePosix(pathOf(args[0])) orelse return Value.nil_val;
    return allocFile(rt, try string_mod.alloc(rt, parent));
}

fn isAbsolute(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    try error_catalog.checkArity("isAbsolute", args, 1, loc);
    return Value.initBoolean(path.isAbsolutePosix(pathOf(args[0])));
}

/// Process cwd path (D-357): `std.process.currentPathAlloc` is the Zig 0.16
/// io-model accessor (the removed `getCwd`/`realpath` were renamed to
/// `currentPath`). Caller frees.
fn cwdAlloc(rt: *Runtime, loc: SourceLocation) anyerror![]u8 {
    return std.process.currentPathAlloc(rt.io, rt.gpa) catch
        return error_catalog.raise(.file_io_error, loc, .{ .op = "getAbsolutePath", .path = ".", .detail = "cannot read the current directory" });
}

/// `.getAbsolutePath` — an absolute path is returned as-is; a relative path is
/// joined onto the process cwd (NO `.`/`..` normalisation — that is
/// getCanonicalPath's job, matching JVM File semantics).
fn getAbsolutePath(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getAbsolutePath", args, 1, loc);
    const p = pathOf(args[0]);
    if (path.isAbsolutePosix(p)) return pathValOf(args[0]);
    const cwd = try cwdAlloc(rt, loc);
    defer rt.gpa.free(cwd);
    const abs = try path.join(rt.gpa, &.{ cwd, p });
    defer rt.gpa.free(abs);
    return string_mod.alloc(rt, abs);
}

/// `.getCanonicalPath` — like getAbsolutePath but lexically resolves `.`/`..`
/// (via resolvePosix). cljw-style DIVERGENCE: symlinks are NOT resolved (the
/// std.Io handle model has no realpath; lexical canonicalisation only, D-357).
fn getCanonicalPath(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("getCanonicalPath", args, 1, loc);
    const p = pathOf(args[0]);
    const abs = if (path.isAbsolutePosix(p))
        try path.resolvePosix(rt.gpa, &.{p})
    else blk: {
        const cwd = try cwdAlloc(rt, loc);
        defer rt.gpa.free(cwd);
        break :blk try path.resolvePosix(rt.gpa, &.{ cwd, p });
    };
    defer rt.gpa.free(abs);
    return string_mod.alloc(rt, abs);
}

/// The File-returning twin of getCanonicalPath. The JVM publishes both
/// spellings of each resolution (`getCanonicalPath` -> String,
/// `getCanonicalFile` -> File), and a caller that keeps composing paths wants
/// the File one so it can go straight back into `new File(parent, child)`.
/// Only the String halves existed here, so `.getCanonicalFile` raised
/// "No implementation of method" on a real library call.
fn getCanonicalFile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("getCanonicalFile", args, 1, loc);
    return allocFile(rt, try getCanonicalPath(rt, env, args, loc));
}

/// The File-returning twin of getAbsolutePath, for the same reason.
fn getAbsoluteFile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    try error_catalog.checkArity("getAbsoluteFile", args, 1, loc);
    return allocFile(rt, try getAbsolutePath(rt, env, args, loc));
}

// --- FS-touching query methods (jail-resolved) ---

fn exists(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("exists", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "exists", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.statKind(rt.io, j orelse p) != null);
}

fn isFile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isFile", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "isFile", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.statKind(rt.io, j orelse p) == .file);
}

fn isDirectory(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("isDirectory", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "isDirectory", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.statKind(rt.io, j orelse p) == .directory);
}

fn length(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("length", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "length", loc);
    defer if (j) |x| rt.gpa.free(x);
    // File sizes below the i48 immediate ceiling (~140 TB) fit initInteger; a
    // larger file is beyond this runtime's realistic scope (would need bignum).
    return Value.initInteger(@intCast(file_io.fileSize(rt.io, j orelse p)));
}

fn canRead(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("canRead", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "canRead", loc);
    defer if (j) |x| rt.gpa.free(x);
    // Read permission is approximated by openability for reading (file_io.exists
    // opens read-mode), which is what every realistic caller actually wants.
    return Value.initBoolean(file_io.exists(rt.io, j orelse p));
}

// --- FS-touching mutation methods (jail-resolved) ---

fn delete(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("delete", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "delete", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.deletePath(rt.io, j orelse p));
}

fn mkdir(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("mkdir", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "mkdir", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.makeDir(rt.io, j orelse p));
}

fn mkdirs(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("mkdirs", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "mkdirs", loc);
    defer if (j) |x| rt.gpa.free(x);
    return Value.initBoolean(file_io.makeDirs(rt.io, j orelse p));
}

// --- statics (ADR-0174 D7) ---

/// `(java.io.File/createTempFile prefix suffix)` — create an empty
/// uniquely-named file under the OS temp dir (`$TMPDIR`, else `/tmp`) and
/// return its `java.io.File`. `suffix` nil → `".tmp"` (JVM default).
/// Uniqueness comes from the monotonic nano clock + a retry counter (no
/// JVM SecureRandom ceremony needed for a name). The candidate path goes
/// through the deploy FS-jail like every other FS touch — a jailed deploy
/// whose temp dir lies outside the jail raises `fs_jail_escape` honestly.
fn createTempFile(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.io.File/createTempFile", args, 2, loc);
    if (args[0].tag() != .string)
        return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.io.File/createTempFile", .actual = @tagName(args[0].tag()) });
    const prefix = string_mod.asString(args[0]);
    const suffix = if (args[1].isNil()) ".tmp" else blk: {
        if (args[1].tag() != .string)
            return error_catalog.raise(.type_arg_not_string, loc, .{ .fn_name = "java.io.File/createTempFile", .actual = @tagName(args[1].tag()) });
        break :blk string_mod.asString(args[1]);
    };
    const tmpdir = std.mem.trimEnd(u8, process_env.get("TMPDIR") orelse "/tmp", "/");
    const base: u64 = @intCast(clock.nanoTime(rt.io));
    var attempt: u64 = 0;
    while (attempt < 100) : (attempt += 1) {
        const candidate = try std.fmt.allocPrint(rt.gpa, "{s}/{s}{d}{s}", .{ tmpdir, prefix, base + attempt, suffix });
        defer rt.gpa.free(candidate);
        const j = try jailed(rt, candidate, "createTempFile", loc);
        defer if (j) |x| rt.gpa.free(x);
        const real = j orelse candidate;
        if (file_io.statKind(rt.io, real) != null) continue; // taken — bump the counter
        file_io.writeAll(rt.io, real, "") catch
            return error_catalog.raise(.file_io_error, loc, .{ .op = "createTempFile", .path = candidate, .detail = "cannot create the temp file" });
        return allocFile(rt, try string_mod.alloc(rt, candidate));
    }
    return error_catalog.raise(.file_io_error, loc, .{ .op = "createTempFile", .path = tmpdir, .detail = "could not find a unique temp-file name" });
}

/// `(java.io.File/listRoots)` — a cljw Java array of the one POSIX
/// filesystem root, `/` (JVM returns `File[]`; Windows' drive letters do
/// not apply to the shipped Mac/Linux targets).
fn listRoots(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("java.io.File/listRoots", args, 0, loc);
    // `root` is an unrooted local across the array alloc below (see `list`).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    const root = try allocFile(rt, try string_mod.alloc(rt, "/"));
    return java_array.fromSlice(rt, &.{root});
}

// --- listing (cljw vector, not a JVM array — see module divergence note) ---

fn list(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("list", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "list", loc);
    defer if (j) |x| rt.gpa.free(x);
    const names = (try file_io.listDir(rt.io, rt.gpa, j orelse p)) orelse return Value.nil_val;
    defer {
        for (names) |n| rt.gpa.free(n);
        rt.gpa.free(names);
    }
    // auto-collect is off (see server.zig buildRequest): build without rooting.
    // That premise does not hold under CLJW_GC_TORTURE_ALLOC (or any allocation
    // that triggers a collection): `v` is an unrooted Zig local, and a collection
    // at the next string alloc swept the half-built vector, so `.list` came back
    // empty or corrupt. Build inside a fabrication region, like the http client.
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var v = vector_mod.empty();
    for (names) |n| v = try vector_mod.conj(rt, v, try string_mod.alloc(rt, n));
    return v;
}

fn listFiles(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = env;
    try error_catalog.checkArity("listFiles", args, 1, loc);
    const p = pathOf(args[0]);
    const j = try jailed(rt, p, "listFiles", loc);
    defer if (j) |x| rt.gpa.free(x);
    const names = (try file_io.listDir(rt.io, rt.gpa, j orelse p)) orelse return Value.nil_val;
    defer {
        for (names) |n| rt.gpa.free(n);
        rt.gpa.free(names);
    }
    // Fabrication region: `v` is an unrooted local and every child File is a
    // GC allocation that can trigger a collection (see `list`).
    rt.gc.enterFabrication();
    defer rt.gc.exitFabrication();
    var v = vector_mod.empty();
    for (names) |n| {
        const child = try path.join(rt.gpa, &.{ p, n });
        defer rt.gpa.free(child);
        v = try vector_mod.conj(rt, v, try allocFile(rt, try string_mod.alloc(rt, child)));
    }
    return v;
}

// --- GC trace + registration ---

/// GC-trace the path string held in state[0]. GC-ROOT: §H — the Value lives in a
/// raw u64 slot the field-walker can't see; a future moving GC must RELOCATE here
/// [ref: .dev/gc_rooting.md §H, debt D-318].
fn traceState(gc_ptr: *anyopaque, state: *[host_instance.STATE_WORDS]u64) void {
    const gc: *gc_heap_mod.GcHeap = @ptrCast(@alignCast(gc_ptr));
    const pv: Value = @enumFromInt(state[0]);
    if (pv.heapHeader()) |hdr| mark_sweep.mark(gc, hdr);
}

const MethodSpec = struct { name: []const u8, f: *const fn (*Runtime, *Env, []const Value, SourceLocation) anyerror!Value };

const METHODS = [_]MethodSpec{
    .{ .name = "<init>", .f = &initFileInstance },
    // `toString` reuses getPath (JVM File.toString == getPath); print.zig's
    // host_instance `str` form looks up "toString" on the descriptor.
    .{ .name = "toString", .f = &getPath },
    .{ .name = "compareTo", .f = &compareTo },
    .{ .name = "getName", .f = &getName },
    .{ .name = "getPath", .f = &getPath },
    .{ .name = "getParent", .f = &getParent },
    .{ .name = "getParentFile", .f = &getParentFile },
    .{ .name = "isAbsolute", .f = &isAbsolute },
    // Each resolution is published in both JVM spellings, the String half and
    // the File half. Only the String halves were registered before.
    .{ .name = "getAbsolutePath", .f = &getAbsolutePath },
    .{ .name = "getAbsoluteFile", .f = &getAbsoluteFile },
    .{ .name = "getCanonicalPath", .f = &getCanonicalPath },
    .{ .name = "getCanonicalFile", .f = &getCanonicalFile },
    .{ .name = "exists", .f = &exists },
    .{ .name = "isFile", .f = &isFile },
    .{ .name = "isDirectory", .f = &isDirectory },
    .{ .name = "length", .f = &length },
    .{ .name = "canRead", .f = &canRead },
    .{ .name = "delete", .f = &delete },
    .{ .name = "mkdir", .f = &mkdir },
    .{ .name = "mkdirs", .f = &mkdirs },
    .{ .name = "list", .f = &list },
    .{ .name = "listFiles", .f = &listFiles },
    // statics (ADR-0174 D7) — same flat table, dispatched as static_method
    .{ .name = "createTempFile", .f = &createTempFile },
    .{ .name = "listRoots", .f = &listRoots },
};

fn initFile(td: *type_descriptor.TypeDescriptor, gpa: std.mem.Allocator) anyerror!void {
    if (td.method_table.len != 0) return; // idempotent
    file_descriptor = td;
    td.host_trace = &traceState;
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
    .cljw_ns = "cljw.java.io.File",
    .descriptor = &descriptor,
    .init = &initFile,
};

/// Path separators (ADR-0174 D7). POSIX values — cljw ships Mac/Linux;
/// a Windows build would flip these with the target (same source of truth
/// as System.zig's staticProperty table).
const file_static_fields = [_]type_descriptor.TypeDescriptor.StaticField{
    .{ .name = "separator", .value = .{ .string = "/" } },
    .{ .name = "separatorChar", .value = .{ .char = '/' } },
    .{ .name = "pathSeparator", .value = .{ .string = ":" } },
    .{ .name = "pathSeparatorChar", .value = .{ .char = ':' } },
};

var descriptor: type_descriptor.TypeDescriptor = .{
    .fqcn = "java.io.File",
    .kind = .native,
    .field_layout = null,
    .protocol_impls = &.{},
    .method_table = &.{},
    .static_fields = &file_static_fields,
    .parent = null,
    .meta = .nil_val,
};
