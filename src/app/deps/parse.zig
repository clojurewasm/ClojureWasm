// SPDX-License-Identifier: EPL-2.0
//! deps.edn source → `DepsConfig` (Convergence Campaign Stage 1.2).
//!
//! Parse-only: turns deps.edn text into a structured config by reusing the
//! cw v1 reader (`eval/reader.zig`) rather than hand-rolling an EDN walk
//! (the v0 `deps.zig` divergence — cw's reader already pre-splits ns/name on
//! keywords/symbols). Resolution (alias merge, `:local/root` join, classpath
//! expansion) lives in the sibling `resolve.zig`; git fetch in `git_fetch.zig`.
//!
//! Source-only by policy (matches v0): `:mvn/version` is rejected via the
//! error catalog, never resolved. All allocations are on the caller's
//! allocator (an arena at the call site), so there is no per-field free.

const std = @import("std");
const reader = @import("../../eval/reader.zig");
const form_mod = @import("../../eval/form.zig");
const Form = form_mod.Form;
const error_catalog = @import("../../runtime/error/catalog.zig");

/// One `:deps` entry: a library coordinate. Exactly one of `local_root` /
/// `git_url` is the resolution source (Maven is rejected at parse time).
pub const Dep = struct {
    /// The lib symbol as written, e.g. `"medley/medley"`.
    lib: []const u8,
    /// `:local/root` — a path (relative to the deps.edn dir, joined at resolve).
    local_root: ?[]const u8 = null,
    /// `:git/url` + `:git/sha` — a git coordinate (fetched in slice 5).
    git_url: ?[]const u8 = null,
    git_sha: ?[]const u8 = null,
    /// `:deps/root` — monorepo subdirectory within the dep.
    deps_root: ?[]const u8 = null,
};

/// Structured deps.edn. Fields land slice by slice; `:aliases` follows.
pub const DepsConfig = struct {
    /// `:paths` — source directories (the base classpath).
    paths: []const []const u8 = &.{},
    /// `:deps` — library coordinates.
    deps: []const Dep = &.{},
};

/// Parse deps.edn `source` into a `DepsConfig`. The top form must be a map;
/// recognised keys are populated, unknown keys ignored (forward-compatible).
/// Raises `feature_not_supported` on a `:mvn/version` dep (source-only policy).
/// Strings reference the reader's form storage, so they share the caller's
/// allocator lifetime.
pub fn parseDepsEdn(allocator: std.mem.Allocator, source: []const u8) !DepsConfig {
    const top = try reader.readOne(allocator, source) orelse return .{};
    const pairs = switch (top.data) {
        .map => |kvs| kvs,
        else => return .{},
    };
    var cfg: DepsConfig = .{};
    // Map forms are flat `[k1, v1, k2, v2, ...]`.
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const key = pairs[i].data;
        if (key != .keyword or key.keyword.ns != null) continue;
        if (std.mem.eql(u8, key.keyword.name, "paths")) {
            cfg.paths = try collectStringVec(allocator, pairs[i + 1]);
        } else if (std.mem.eql(u8, key.keyword.name, "deps")) {
            cfg.deps = try parseDeps(allocator, pairs[i + 1]);
        }
    }
    return cfg;
}

/// Collect a vector-of-strings form into a `[][]const u8`. Non-vectors and
/// non-string elements are skipped (a malformed `:paths` yields the strings
/// it can, matching v0's lenient parse).
fn collectStringVec(allocator: std.mem.Allocator, v: Form) ![]const []const u8 {
    const elems = switch (v.data) {
        .vector => |e| e,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (elems) |e| switch (e.data) {
        .string => |s| try out.append(allocator, s),
        else => {},
    };
    return out.toOwnedSlice(allocator);
}

/// Parse the `:deps` map `{lib-sym dep-map, ...}` into `[]Dep`.
fn parseDeps(allocator: std.mem.Allocator, v: Form) ![]const Dep {
    const pairs = switch (v.data) {
        .map => |kvs| kvs,
        else => return &.{},
    };
    var out: std.ArrayList(Dep) = .empty;
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const lib = switch (pairs[i].data) {
            .symbol => |s| if (s.ns) |ns| try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, s.name }) else s.name,
            else => continue,
        };
        try out.append(allocator, try parseDep(lib, pairs[i + 1]));
    }
    return out.toOwnedSlice(allocator);
}

/// Parse one dep-map `{:local/root "..."}` / `{:git/url "..." :git/sha "..."}`.
/// A `:mvn/version` key is rejected (ClojureWasm resolves source-only).
fn parseDep(lib: []const u8, dep_form: Form) !Dep {
    var dep: Dep = .{ .lib = lib };
    const pairs = switch (dep_form.data) {
        .map => |kvs| kvs,
        else => return dep,
    };
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const k = pairs[i].data;
        if (k != .keyword) continue;
        const ns = k.keyword.ns orelse "";
        const name = k.keyword.name;
        const val = strOf(pairs[i + 1]);
        if (std.mem.eql(u8, ns, "mvn") and std.mem.eql(u8, name, "version")) {
            return error_catalog.raise(.feature_not_supported, dep_form.location, .{
                .name = "Maven/Clojars dependency (:mvn/version) — ClojureWasm resolves source-only; use :git/url + :git/sha instead",
            });
        } else if (std.mem.eql(u8, ns, "local") and std.mem.eql(u8, name, "root")) {
            dep.local_root = val;
        } else if (std.mem.eql(u8, ns, "git") and std.mem.eql(u8, name, "url")) {
            dep.git_url = val;
        } else if (std.mem.eql(u8, ns, "git") and std.mem.eql(u8, name, "sha")) {
            dep.git_sha = val;
        } else if (std.mem.eql(u8, ns, "deps") and std.mem.eql(u8, name, "root")) {
            dep.deps_root = val;
        }
    }
    return dep;
}

/// The string value of a form, or null for a non-string.
fn strOf(v: Form) ?[]const u8 {
    return switch (v.data) {
        .string => |s| s,
        else => null,
    };
}

test "parse: :paths only" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseDepsEdn(arena.allocator(), "{:paths [\"src\" \"resources\"]}");
    try testing.expectEqual(@as(usize, 2), cfg.paths.len);
    try testing.expectEqualStrings("src", cfg.paths[0]);
    try testing.expectEqualStrings("resources", cfg.paths[1]);
}

test "parse: :deps :local/root" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseDepsEdn(arena.allocator(), "{:deps {my-utils/my-utils {:local/root \"../my-utils\"}}}");
    try testing.expectEqual(@as(usize, 1), cfg.deps.len);
    try testing.expectEqualStrings("my-utils/my-utils", cfg.deps[0].lib);
    try testing.expectEqualStrings("../my-utils", cfg.deps[0].local_root.?);
}

test "parse: :deps :git/url + :git/sha + :deps/root" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseDepsEdn(arena.allocator(),
        "{:deps {mono/lib {:git/url \"https://x\" :git/sha \"abc123\" :deps/root \"libs/core\"}}}");
    try testing.expectEqual(@as(usize, 1), cfg.deps.len);
    try testing.expectEqualStrings("https://x", cfg.deps[0].git_url.?);
    try testing.expectEqualStrings("abc123", cfg.deps[0].git_sha.?);
    try testing.expectEqualStrings("libs/core", cfg.deps[0].deps_root.?);
}

test "parse: :mvn/version is rejected (source-only)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.NotImplemented, parseDepsEdn(arena.allocator(),
        "{:deps {x/y {:mvn/version \"1.0\"}}}"));
}
