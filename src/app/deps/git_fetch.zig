// SPDX-License-Identifier: EPL-2.0
//! deps.edn `:git/url` resolution: clone a repo at a pinned sha into a
//! content-addressed cache (Convergence Campaign Stage 1.2 slice 5, ADR-0101).
//!
//! This is the ONLY module in cw v1 that spawns a subprocess — the audit
//! invariant is `rg 'std.process.Child' src/` resolves here (`std.process.run`
//! wraps Child). `git` is invoked by argv vector (never a shell string), so a
//! `:git/url` cannot inject shell metacharacters.
//!
//! Cache layout (ADR-0101 Shape B): `<cache_base>/gitlibs/<repo>/<full-sha>/`,
//! content-addressed on the FULL sha so multiple shas of one repo coexist. The
//! caller resolves `cache_base` from `$CLJW_HOME` (default `~/.cljw`) at the app
//! boundary and passes it in — this module reads no environment, so it is
//! unit-testable against a temp cache + a `file://` repo.
//!
//! Algorithm: cache hit → return; miss → clone into a `.tmp` sibling, checkout
//! the sha, verify `rev-parse HEAD == :git/sha`, then atomically rename the tmp
//! into place (a half-clone or SIGINT never poisons the cache).

const std = @import("std");
const error_catalog = @import("../../runtime/error/catalog.zig");

/// Ensure `url`@`sha` is cached and return the absolute cache directory.
/// `cache_base` null (no `$CLJW_HOME`/`$HOME`) → `lib_load_failed`. `coord` is
/// the lib coordinate, used only in error messages.
pub fn ensureCached(
    io: std.Io,
    allocator: std.mem.Allocator,
    cache_base: ?[]const u8,
    url: []const u8,
    sha: []const u8,
    coord: []const u8,
) ![]const u8 {
    const base = cache_base orelse return fail(coord, "no $CLJW_HOME or $HOME for the git cache");
    const repo = repoName(url);
    const cwd = std.Io.Dir.cwd();
    const dir = try std.fmt.allocPrint(allocator, "{s}/gitlibs/{s}/{s}", .{ base, repo, sha });

    // Cache hit — the sha dir already exists.
    if (cwd.access(io, dir, .{})) |_| {
        return dir;
    } else |_| {
        // Cache miss → clone below.
    }

    const parent = try std.fmt.allocPrint(allocator, "{s}/gitlibs/{s}", .{ base, repo });
    cwd.createDirPath(io, parent) catch |e| return fail(coord, @errorName(e));
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dir});
    cwd.deleteTree(io, tmp) catch {}; // clear a stale interrupted clone

    try runGit(io, allocator, coord, &.{ "git", "clone", "--quiet", url, tmp });
    try runGit(io, allocator, coord, &.{ "git", "-C", tmp, "checkout", "--quiet", sha });

    // Verify the checked-out HEAD matches the requested sha (catch a moved tag
    // / tampered mirror). A short `:git/sha` is a prefix of the full HEAD.
    const head = try gitStdout(io, allocator, coord, &.{ "git", "-C", tmp, "rev-parse", "HEAD" });
    const got = std.mem.trim(u8, head, " \t\r\n");
    if (!std.mem.startsWith(u8, got, sha) and !std.mem.startsWith(u8, sha, got)) {
        return fail(coord, "checked-out HEAD does not match :git/sha");
    }

    cwd.rename(tmp, cwd, dir, io) catch |e| return fail(coord, @errorName(e));
    return dir;
}

/// The repo directory name: the last `/`-segment of `url`, minus a `.git`
/// suffix (`https://x/y/medley.git` → `medley`; `file:///t/bare.git` → `bare`).
fn repoName(url: []const u8) []const u8 {
    var name = url;
    if (std.mem.findScalarLast(u8, name, '/')) |i| name = name[i + 1 ..];
    if (std.mem.endsWith(u8, name, ".git")) name = name[0 .. name.len - 4];
    return if (name.len == 0) "repo" else name;
}

/// Run `git ...`, raising `lib_load_failed` on spawn error or non-zero exit
/// (the git stderr becomes the error detail).
fn runGit(io: std.Io, allocator: std.mem.Allocator, coord: []const u8, argv: []const []const u8) !void {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch |e|
        return fail(coord, @errorName(e));
    switch (res.term) {
        .exited => |code| if (code != 0) {
            const detail = std.mem.trim(u8, res.stderr, " \t\r\n");
            return fail(coord, if (detail.len > 0) detail else "git command failed");
        },
        else => return fail(coord, "git terminated abnormally"),
    }
}

/// Run `git ...` and return its trimmed stdout, raising on failure.
fn gitStdout(io: std.Io, allocator: std.mem.Allocator, coord: []const u8, argv: []const []const u8) ![]const u8 {
    const res = std.process.run(allocator, io, .{ .argv = argv }) catch |e|
        return fail(coord, @errorName(e));
    switch (res.term) {
        .exited => |code| if (code != 0) return fail(coord, "git command failed"),
        else => return fail(coord, "git terminated abnormally"),
    }
    return res.stdout;
}

fn fail(coord: []const u8, detail: []const u8) error_catalog.ClojureWasmError {
    return error_catalog.raise(.lib_load_failed, .{}, .{ .ns = coord, .detail = detail });
}

test "repoName strips path + .git suffix" {
    const t = std.testing;
    try t.expectEqualStrings("medley", repoName("https://github.com/weavejester/medley.git"));
    try t.expectEqualStrings("medley", repoName("https://github.com/weavejester/medley"));
    try t.expectEqualStrings("bare", repoName("file:///tmp/bare.git"));
}
