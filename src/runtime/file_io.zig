// SPDX-License-Identifier: EPL-2.0
//! Filesystem I/O primitives — namespace-neutral implementation
//! per F-009.
//!
//! Surfaces consume this:
//!   - `lang/primitive/io.zig` — `clojure.core/slurp` /
//!     `clojure.core/spit`.
//!   - `runtime/java/io/File.zig` — `java.io.File` instance
//!     methods (.exists / .length / read / write).
//!   - `runtime/java/nio/file/Files.zig` — a future surface for
//!     modern NIO methods (not yet present).
//!
//! This file covers whole-file read + write. Streaming / append-mode /
//! transactional rename are future additions.

const std = @import("std");

/// Read the entire file at `path` into a freshly-allocated byte
/// slice. Caller owns the returned slice and must free it via
/// `allocator`.
pub fn readAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    return try file_reader.interface.allocRemaining(allocator, .unlimited);
}

/// Write `content` to `path`, replacing any existing file.
pub fn writeAll(io: std.Io, path: []const u8, content: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    try file_writer.interface.writeAll(content);
    try file_writer.interface.flush();
}

/// Append `content` to `path` (creating it if absent) — backs `spit`'s
/// `:append true` option. Whole-file read-then-write (spit's own whole-file
/// semantics); NOT a streaming append. A missing file degrades to a plain write.
pub fn appendAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const existing = readAll(io, allocator, path) catch |e| switch (e) {
        error.FileNotFound => return writeAll(io, path, content),
        else => return e,
    };
    defer allocator.free(existing);
    const combined = try std.mem.concat(allocator, u8, &.{ existing, content });
    defer allocator.free(combined);
    try writeAll(io, path, combined);
}

/// Predicate: does `path` exist (file or directory)?
pub fn exists(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    file.close(io);
    return true;
}

// --- java.io.File metadata + mutation (ADR-0126; namespace-neutral per F-009) ---
// Each operates on an already-jail-resolved path (the surface calls jailResolve
// first). `statKind` is the single existence/type probe: null == the path does
// not exist (or could not be stat'd), so `exists`/`isFile`/`isDirectory` all
// derive from it without three separate syscalls' worth of distinct logic.

/// `stat` a path, following symlinks. Returns null when the path does not exist
/// (or cannot be stat'd — treated as absent, matching `java.io.File`'s
/// "missing → false/0" contract for every query method).
pub fn statKind(io: std.Io, path: []const u8) ?std.Io.File.Kind {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.kind;
}

/// Byte length of `path`, or 0 when it does not exist / is not a regular file
/// (java.io.File.length()'s documented behaviour for non-files).
pub fn fileSize(io: std.Io, path: []const u8) u64 {
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return st.size;
}

/// `mkdir` — create exactly one directory. False on any failure (already
/// exists, missing parent, permission), mirroring File.mkdir()'s boolean.
pub fn makeDir(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch return false;
    return true;
}

/// `mkdirs` — create the directory and any missing parents. False on failure.
pub fn makeDirs(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().createDirPath(io, path) catch return false;
    return true;
}

/// `delete` — remove a file or (empty) directory. False when nothing was
/// deleted (absent / non-empty dir / permission), mirroring File.delete().
pub fn deletePath(io: std.Io, path: []const u8) bool {
    if (std.Io.Dir.cwd().deleteFile(io, path)) |_| {
        return true;
    } else |_| {
        // deleteFile failed (path is a directory, or absent) — fall through to
        // deleteDir; a still-failing deleteDir means nothing was removed.
    }
    std.Io.Dir.cwd().deleteDir(io, path) catch return false;
    return true;
}

/// List the entry names of directory `path`. Returns null when `path` is not a
/// readable directory (java.io.File.list() returns null then). Caller owns the
/// returned slice AND each name slice (free each, then the outer slice).
pub fn listDir(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !?[][]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return try names.toOwnedSlice(alloc);
}

/// Error from the deploy-mode FS jail (ADR-0123 / SE-6/7).
pub const JailError = error{FsJailEscape} || std.mem.Allocator.Error;

/// Resolve `path` under the deploy-mode filesystem jail (ADR-0123, SE-6/7) and
/// return the absolute path the caller must actually open. When `root` is null
/// the jail is OFF (local CLI) and this returns `null` — the caller opens the
/// ORIGINAL `path` (cwd-relative, unchanged). When `root` is set, `path` is
/// confined to that subtree: it is resolved under `root` (lexical `.`/`..`) and
/// must land at `root` itself or strictly beneath it — a `..` traversal or an
/// absolute path outside the root raises `error.FsJailEscape`.
///
/// The returned slice is the path to OPEN (caller owns it, free via `alloc`), so
/// the file actually accessed is the one that was containment-checked — checking
/// against `root` but opening against cwd would validate one path and read
/// another. Every FS surface (slurp / spit / wasm/load) calls this, so the policy
/// lives in one place (F-009).
///
/// LEXICAL only: a symlink planted INSIDE the jail pointing outside is still
/// followed (documented residual D-342 — mount the jail read-only / forbid
/// symlinks for full confinement; the symlink-safe finished form is scheduled).
/// A non-absolute `root` is a deploy misconfiguration and fails CLOSED (deny all)
/// rather than confining against an ambiguous cwd-relative base.
pub fn jailResolve(alloc: std.mem.Allocator, root: ?[]const u8, path: []const u8) JailError!?[]u8 {
    const r = root orelse return null;
    // Reject an embedded NUL before the lexical resolve: resolvePosix treats NUL
    // as an ordinary byte (so `..\x00` is NOT seen as `..` and passes containment),
    // but the kernel's C-string `open` truncates at the NUL — opening a different,
    // possibly-escaping path than the one checked. In ReleaseFast the posix
    // NUL-absence assert is compiled out, so this guard is the only defense
    // (check-vs-open must agree). No legit path contains a NUL.
    if (std.mem.findScalar(u8, path, 0) != null or std.mem.findScalar(u8, r, 0) != null)
        return error.FsJailEscape;
    if (!std.Io.Dir.path.isAbsolute(r)) return error.FsJailEscape;
    const root_abs = try std.Io.Dir.path.resolvePosix(alloc, &.{r});
    defer alloc.free(root_abs);
    // An absolute `path` makes resolvePosix reset to it, so it falls out of the
    // root and the containment check below rejects it (= absolute paths outside
    // the root are denied; an absolute path inside resolves to within and is ok).
    const full = try std.Io.Dir.path.resolvePosix(alloc, &.{ root_abs, path });
    if (!withinRoot(full, root_abs)) {
        alloc.free(full);
        return error.FsJailEscape;
    }
    return full;
}

/// True iff absolute path `p` is `root` itself or strictly beneath it. `root` is
/// assumed already lexically resolved (no trailing `/` except the degenerate
/// `"/"`). The `p[root.len] == '/'` boundary guard distinguishes `/jail/x` (in)
/// from a sibling `/jailX` (out).
fn withinRoot(p: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, p, root)) return false;
    if (p.len == root.len) return true;
    if (root[root.len - 1] == '/') return true; // root == "/" (resolvePosix keeps its slash)
    return p[root.len] == '/';
}

// --- tests ---

const testing = std.testing;

/// Test helper: assert `jailResolve` allows `path` and returns the expected
/// resolved absolute path (then free it).
fn expectJailOk(root: ?[]const u8, path: []const u8, want: []const u8) !void {
    const got = (try jailResolve(testing.allocator, root, path)) orelse return error.TestUnexpectedNull;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "jailResolve: null root is a no-op (jail off) → returns null" {
    try testing.expectEqual(@as(?[]u8, null), try jailResolve(testing.allocator, null, "/anything/at/all"));
    try testing.expectEqual(@as(?[]u8, null), try jailResolve(testing.allocator, null, "../../etc/passwd"));
}

test "jailResolve: confined relative paths resolve under the root" {
    const root = "/srv/app/data";
    try expectJailOk(root, "file.txt", "/srv/app/data/file.txt");
    try expectJailOk(root, "sub/dir/file.txt", "/srv/app/data/sub/dir/file.txt");
    try expectJailOk(root, "./a/./b", "/srv/app/data/a/b");
    try expectJailOk(root, "a/../b", "/srv/app/data/b"); // stays inside
    try expectJailOk(root, "", "/srv/app/data"); // root itself
    try expectJailOk(root, ".", "/srv/app/data");
}

test "jailResolve: .. traversal past root is rejected" {
    const root = "/srv/app/data";
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "../secret"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "../../etc/passwd"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "a/../../escape"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "sub/../../../etc"));
}

test "jailResolve: an absolute path OUTSIDE the root is rejected" {
    const root = "/srv/app/data";
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "/etc/passwd"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "/srv/app/database/x"));
}

test "jailResolve: an absolute path INSIDE the root resolves to within and is allowed" {
    // resolvePosix resets to the absolute path, then containment checks it like
    // any other — an absolute path that lands inside the jail is fine (safe), an
    // absolute path outside is rejected (above). No silent escape either way.
    const root = "/srv/app/data";
    try expectJailOk(root, "/srv/app/data", "/srv/app/data");
    try expectJailOk(root, "/srv/app/data/sub/file.txt", "/srv/app/data/sub/file.txt");
}

test "jailResolve: sibling-prefix boundary is not an escape hatch" {
    // /srv/app/data vs /srv/app/database — startsWith without the boundary
    // guard would wrongly admit the sibling.
    const root = "/srv/app/data";
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "../database/x"));
}

test "jailResolve: non-absolute root fails closed" {
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, "relative/root", "file.txt"));
}

test "jailResolve: an embedded NUL is rejected (lexical-vs-kernel-truncation bypass)" {
    const root = "/srv/app/data";
    // `..\x00...` would pass the lexical containment (the segment is not `..`)
    // but the kernel truncates at NUL to `/srv/app/data/..` = /srv/app (escape).
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "..\x00/escape"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "ok\x00"));
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, root, "sub/file\x00.txt"));
    // NUL in the root itself is also rejected.
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, "/srv/app\x00/data", "file.txt"));
}

test "jailResolve: root with trailing slash + double slashes normalise" {
    try expectJailOk("/srv/app/data/", "a//b", "/srv/app/data/a/b");
    try testing.expectError(error.FsJailEscape, jailResolve(testing.allocator, "/srv/app/data/", "../up"));
}

test "withinRoot: degenerate root \"/\" admits any absolute path" {
    try testing.expect(withinRoot("/etc/passwd", "/"));
    try testing.expect(withinRoot("/", "/"));
    try testing.expect(!withinRoot("relative", "/"));
}

test "writeAll then readAll round-trips" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();

    const tmp_path = "/tmp/cljw_file_io_test_67";
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try writeAll(io, tmp_path, "hello world");
    const content = try readAll(io, testing.allocator, tmp_path);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello world", content);
}

test "exists distinguishes present from missing" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();

    const tmp_path = "/tmp/cljw_file_io_test_exists";
    defer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    try testing.expect(!exists(io, tmp_path));
    try writeAll(io, tmp_path, "x");
    try testing.expect(exists(io, tmp_path));
}

test "statKind / fileSize distinguish file, dir, and missing" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();

    const base = "/tmp/cljw_file_io_statkind";
    const f = base ++ "/a.txt";
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try testing.expect(makeDirs(io, base));
    try writeAll(io, f, "abcde");

    try testing.expectEqual(@as(?std.Io.File.Kind, .file), statKind(io, f));
    try testing.expectEqual(@as(?std.Io.File.Kind, .directory), statKind(io, base));
    try testing.expectEqual(@as(?std.Io.File.Kind, null), statKind(io, base ++ "/missing"));
    try testing.expectEqual(@as(u64, 5), fileSize(io, f));
    try testing.expectEqual(@as(u64, 0), fileSize(io, base ++ "/missing"));
}

test "makeDir / makeDirs / deletePath booleans" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();

    const base = "/tmp/cljw_file_io_mkdir";
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};

    try testing.expect(makeDirs(io, base ++ "/x/y")); // creates parents
    try testing.expect(makeDir(io, base ++ "/x/z")); // single under existing parent
    try testing.expect(!makeDir(io, base ++ "/nope/deep")); // missing parent → false
    try testing.expect(deletePath(io, base ++ "/x/z")); // remove empty dir
    try testing.expect(!deletePath(io, base ++ "/x/z")); // already gone → false
}

test "listDir returns names, null for a non-directory" {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    const io = th.io();

    const base = "/tmp/cljw_file_io_listdir";
    defer std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try testing.expect(makeDirs(io, base));
    try writeAll(io, base ++ "/one", "1");
    try writeAll(io, base ++ "/two", "2");

    const names = (try listDir(io, testing.allocator, base)).?;
    defer {
        for (names) |n| testing.allocator.free(n);
        testing.allocator.free(names);
    }
    try testing.expectEqual(@as(usize, 2), names.len);

    // A regular file is not a directory → null.
    try testing.expectEqual(@as(?[][]u8, null), try listDir(io, testing.allocator, base ++ "/one"));
}
