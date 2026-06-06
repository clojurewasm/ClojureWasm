// SPDX-License-Identifier: EPL-2.0
//! deps.edn `DepsConfig` → an expanded classpath (Convergence Campaign
//! Stage 1.2).
//!
//! `resolveClasspath` turns a parsed config (rooted at the deps.edn directory)
//! into a list of source directories for `rt.load_paths`: the `:paths` joined
//! to the deps.edn dir, plus each `:local/root` dep's own classpath
//! (transitively — the local dep's `deps.edn` is read and expanded, with a
//! visited-set breaking cycles). Git deps (`:git/url`) are skipped here; they
//! land in the sibling `git_fetch.zig` behind an inline ADR (slice 5).
//!
//! Paths are joined `dir/sub` (mirroring `require_resolver.zig`'s relative
//! path idiom) rather than absolutised, so a relative deps.edn dir stays
//! relative. All allocations are on the caller's (arena) allocator.

const std = @import("std");
const parse = @import("parse.zig");
const DepsConfig = parse.DepsConfig;
const file_io = @import("../../runtime/file_io.zig");
const git_fetch = @import("git_fetch.zig");

/// Expand `cfg` (rooted at `deps_dir`) into a classpath: `:paths` first, then
/// each `:local/root` dep's transitive classpath, then each selected alias's
/// `:extra-paths` + `:extra-deps`. `io` is used only to read local deps'
/// `deps.edn` files; a `:paths`-only config never touches it. `alias_names`
/// are the `-A:name` selections (empty = base config only).
pub fn resolveClasspath(
    io: std.Io,
    allocator: std.mem.Allocator,
    deps_dir: []const u8,
    cfg: DepsConfig,
    alias_names: []const []const u8,
    git_cache_base: ?[]const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try expand(io, allocator, deps_dir, cfg.paths, cfg.deps, &out, &visited, git_cache_base);
    for (alias_names) |name| {
        const al = findAlias(cfg.aliases, name) orelse continue;
        try expand(io, allocator, deps_dir, al.extra_paths, al.extra_deps, &out, &visited, git_cache_base);
    }
    return out.toOwnedSlice(allocator);
}

fn findAlias(aliases: []const parse.Alias, name: []const u8) ?parse.Alias {
    for (aliases) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

fn expand(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: []const u8,
    paths: []const []const u8,
    deps: []const parse.Dep,
    out: *std.ArrayList([]const u8),
    visited: *std.StringHashMapUnmanaged(void),
    git_cache_base: ?[]const u8,
) !void {
    for (try expandPaths(allocator, dir, paths)) |p| try out.append(allocator, p);
    for (deps) |dep| {
        // A dep's source dir is either a `:local/root` (joined to `dir`) or a
        // fetched `:git/url` (cloned into the cache, then `:deps/root`-joined).
        const dep_dir = if (dep.local_root) |lr|
            try join(allocator, dir, lr)
        else if (dep.git_url) |url| blk: {
            const sha = dep.git_sha orelse continue; // :git/url without :git/sha
            const cache = try git_fetch.ensureCached(io, allocator, git_cache_base, url, sha, dep.lib);
            break :blk if (dep.deps_root) |dr| try join(allocator, cache, dr) else cache;
        } else continue;
        if (visited.contains(dep_dir)) continue;
        try visited.put(allocator, dep_dir, {});
        if (try readDepsEdn(io, allocator, dep_dir)) |sub| {
            try expand(io, allocator, dep_dir, sub.paths, sub.deps, out, visited, git_cache_base);
        } else {
            // No deps.edn → the tools.deps default classpath is `["src"]`.
            const src_dir = try join(allocator, dep_dir, "src");
            if (std.Io.Dir.cwd().access(io, src_dir, .{})) |_| {
                try out.append(allocator, src_dir);
            } else |_| {
                // No src/ dir either → the dep contributes nothing.
            }
        }
    }
}

/// Join each of `paths` against `dir` (`dir/p`). I/O-free — the unit-testable
/// core of the `:paths` expansion.
pub fn expandPaths(
    allocator: std.mem.Allocator,
    dir: []const u8,
    paths: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (paths) |p| try out.append(allocator, try join(allocator, dir, p));
    return out.toOwnedSlice(allocator);
}

/// Read + parse `dir/deps.edn`; null when the file is absent (a local dep need
/// not declare its own deps.edn — it just contributes nothing transitively).
fn readDepsEdn(io: std.Io, allocator: std.mem.Allocator, dir: []const u8) !?DepsConfig {
    const path = try join(allocator, dir, "deps.edn");
    const src = file_io.readAll(io, allocator, path) catch |e| switch (e) {
        error.FileNotFound, error.NotDir, error.BadPathName => return null,
        else => return e,
    };
    return try parse.parseDepsEdn(allocator, src);
}

fn join(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, b });
}

test "resolve: :paths joined to deps dir" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try expandPaths(a, "proj", &.{ "src", "resources" });
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("proj/src", got[0]);
    try testing.expectEqualStrings("proj/resources", got[1]);
}
