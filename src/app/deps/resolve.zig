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
const mvn_fetch = @import("mvn_fetch.zig");
const git_fetch = @import("git_fetch.zig");

/// Expand `cfg` (rooted at `deps_dir`) into a classpath: `:paths` first, then
/// each `:local/root` dep's transitive classpath, then each selected alias's
/// `:extra-paths` + `:extra-deps`. `io` is used only to read local deps'
/// `deps.edn` files; a `:paths`-only config never touches it. `alias_names`
/// are the `-A:name` selections (empty = base config only).
/// `skipped` (optional) collects the lib names of `:mvn`-only deps that were
/// skipped (source-only policy, ADR-0101 amendment), so the caller can emit a
/// summary warning. `org.clojure/clojure` (cw itself) is omitted — it is always
/// Maven coordinates are now resolved to extracted source roots (see
/// `mvn_fetch.zig`); `skipped` remains for unsupported coordinate shapes.
/// satisfied at require, so warning about it would be pure noise.
pub fn resolveClasspath(
    io: std.Io,
    allocator: std.mem.Allocator,
    deps_dir: []const u8,
    cfg: DepsConfig,
    alias_names: []const []const u8,
    git_cache_base: ?[]const u8,
    skipped: ?*std.ArrayList([]const u8),
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    try expand(io, allocator, deps_dir, cfg.paths, cfg.deps, &out, &visited, git_cache_base, skipped);
    for (alias_names) |name| {
        const al = findAlias(cfg.aliases, name) orelse continue;
        try expand(io, allocator, deps_dir, al.extra_paths, al.extra_deps, &out, &visited, git_cache_base, skipped);
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
    skipped: ?*std.ArrayList([]const u8),
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
        } else if (dep.mvn_version) |version| {
            // Maven jars contribute only Clojure sources; their POM dependencies
            // are expanded recursively by mvn_fetch with coordinate cycle guards.
            try mvn_fetch.expand(io, allocator, dep.lib, version, git_cache_base, out, visited);
            continue;
        } else {
            // No source coord cljw can fetch. A :mvn dep is skipped (source-only
            // policy, ADR-0101 amendment); its lib joins the summary-warning list
            // unless it is `org.clojure/clojure` (cw itself — always satisfied at
            // require). Whether the lib is truly satisfied is decided at require
            // time by namespace availability, not here.
            if (skipped) |sk| {
                if (dep.mvn_version != null and !std.mem.eql(u8, dep.lib, "org.clojure/clojure"))
                    try sk.append(allocator, dep.lib);
            }
            continue;
        };
        if (visited.contains(dep_dir)) continue;
        try visited.put(allocator, dep_dir, {});
        if (try readDepsEdn(io, allocator, dep_dir)) |sub| {
            // tools.deps defaults `:paths` to `["src"]` when unspecified — this
            // applies per-dep too. A dep deps.edn that declares only `:deps`
            // (e.g. medley: `{:deps {org.clojure/clojure {:mvn/version …}}}`,
            // no `:paths`) still has its source under `src/`; without the default
            // it would contribute nothing and `require` would miss it.
            const eff_paths: []const []const u8 = if (sub.paths.len == 0) &.{"src"} else sub.paths;
            try expand(io, allocator, dep_dir, eff_paths, sub.deps, out, visited, git_cache_base, skipped);
        } else {
            // No deps.edn at all → the tools.deps default classpath is `["src"]`.
            const src_dir = try join(allocator, dep_dir, "src");
            if (std.Io.Dir.cwd().access(io, src_dir, .{})) |_| {
                try out.append(allocator, src_dir);
            } else |_| {
                // No src/ dir either → the dep contributes nothing.
            }
            // Maven-layout fallback: an old clojure-contrib git dep (no deps.edn,
            // a pom.xml clj reads but cljw does not) keeps its sources under
            // `src/main/clojure`. tools.deps derives this from the pom; cljw adds
            // the conventional Maven root directly so the lib resolves
            // (data.generators et al.). Harmless when absent.
            const maven_dir = try join(allocator, dep_dir, "src/main/clojure");
            if (std.Io.Dir.cwd().access(io, maven_dir, .{})) |_| {
                try out.append(allocator, maven_dir);
            } else |_| {
                // No Maven-layout dir → contributes nothing (the common case).
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
    // tools.deps parity: an ABSOLUTE :paths / :extra-paths / :local/root entry
    // is used as-is (joining would silently relativise it to `./abs/...`).
    if (std.Io.Dir.path.isAbsolute(b)) return allocator.dupe(u8, b);
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

test "resolve: an absolute :paths entry is used as-is (tools.deps parity)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try expandPaths(a, ".", &.{ ".", "/abs/lib/src" });
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("./.", got[0]);
    try testing.expectEqualStrings("/abs/lib/src", got[1]);
}
