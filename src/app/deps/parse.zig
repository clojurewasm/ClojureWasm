// SPDX-License-Identifier: EPL-2.0
//! deps.edn source → `DepsConfig` (Convergence Campaign Stage 1.2).
//!
//! Parse-only: turns deps.edn text into a structured config by reusing the
//! cw v1 reader (`eval/reader.zig`) rather than hand-rolling an EDN walk
//! (the v0 `deps.zig` divergence — cw's reader already pre-splits ns/name on
//! keywords/symbols). Resolution (alias merge, `:local/root` join, classpath
//! expansion) lives in the sibling `resolve.zig`; git fetch in `git_fetch.zig`.
//!
//! Source-only by policy: `:mvn/version` is recorded (`Dep.mvn_version`) and
//! skipped at resolve (+ a summary warning, suppressed for cw-provided coords
//! like `org.clojure/clojure`), never fetched — see ADR-0101 amendment. All
//! allocations are on the caller's allocator (an arena at the call site), so
//! there is no per-field free.

const std = @import("std");
const reader = @import("../../eval/reader.zig");
const form_mod = @import("../../eval/form.zig");
const Form = form_mod.Form;

/// One `:deps` entry: a library coordinate. The resolution source is a
/// `:local/root` or `:git/url`; a `:mvn/version` coordinate has no source cljw
/// can fetch (no Maven/Clojars), so it is RECORDED (`mvn_version`) and SKIPPED
/// at resolve — not a hard error (ADR-0101 amendment). Whether the lib is
/// actually satisfied is decided at `require` time by namespace availability
/// (cw's bundled namespaces ∪ source-resolved paths); a skipped `:mvn` only
/// bites if its namespace is required and is neither bundled nor source-laid.
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
    /// `:mvn/version` — recorded so resolve can skip (+ summary-warn) rather
    /// than reject. `org.clojure/clojure` (cw itself) is the universal case.
    mvn_version: ?[]const u8 = null,
};

/// One `:aliases` entry. Classpath-affecting keys (`:extra-paths` /
/// `:extra-deps`) plus the `-M`/`-X` run-mode keys (`:main-opts` / `:exec-fn` /
/// `:exec-args`, Stage 1.4 / D-309). The run-mode keys are inert under `-A`
/// (classpath only) and only consulted by `run_mode.zig` under `-M`/`-X`.
pub const Alias = struct {
    /// The alias keyword name, e.g. `"dev"` for `:dev`.
    name: []const u8,
    /// `:extra-paths` — directories added when the alias is selected.
    extra_paths: []const []const u8 = &.{},
    /// `:extra-deps` — extra library coordinates when the alias is selected.
    extra_deps: []const Dep = &.{},
    /// `:main-opts` — the `clojure.main` arg vector run under `-M:alias`
    /// (e.g. `["-m" "my.app"]`). Empty when the alias declares none; the
    /// user's trailing `-M` args are appended at run time (clj append, not
    /// replace).
    main_opts: []const []const u8 = &.{},
    /// `:exec-fn` — the fully-qualified `"ns/name"` invoked under `-X:alias`
    /// with the (merged) `:exec-args` map. Null when the alias declares none
    /// (a trailing CLI symbol can still supply it).
    exec_fn: ?[]const u8 = null,
    /// `:exec-args` — the EDN map passed as the single argument to `:exec-fn`.
    /// Held as the reader Form so `run_mode.zig` can re-serialize it (via
    /// `Form.formatPrStr`) and merge CLI `:key value` overrides over it.
    exec_args: ?Form = null,
};

/// Structured deps.edn. Fields land slice by slice.
pub const DepsConfig = struct {
    /// `:paths` — source directories (the base classpath).
    paths: []const []const u8 = &.{},
    /// `:deps` — library coordinates.
    deps: []const Dep = &.{},
    /// `:aliases` — named overlays selected with `-A:name`.
    aliases: []const Alias = &.{},
};

/// Parse deps.edn `source` into a `DepsConfig`. The top form must be a map;
/// recognised keys are populated, unknown keys ignored (forward-compatible).
/// A `:mvn/version` dep is recorded (`Dep.mvn_version`) and skipped at resolve
/// (source-only policy, ADR-0101 amendment) — not rejected. Strings reference
/// the reader's form storage, so they share the caller's allocator lifetime.
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
        } else if (std.mem.eql(u8, key.keyword.name, "aliases")) {
            cfg.aliases = try parseAliases(allocator, pairs[i + 1]);
        }
    }
    return cfg;
}

/// Parse the `:aliases` map `{:kw alias-map, ...}` into `[]Alias`.
fn parseAliases(allocator: std.mem.Allocator, v: Form) ![]const Alias {
    const pairs = switch (v.data) {
        .map => |kvs| kvs,
        else => return &.{},
    };
    var out: std.ArrayList(Alias) = .empty;
    var i: usize = 0;
    while (i + 1 < pairs.len) : (i += 2) {
        const name = switch (pairs[i].data) {
            .keyword => |k| k.name,
            else => continue,
        };
        var alias: Alias = .{ .name = name };
        if (pairs[i + 1].data == .map) {
            const akvs = pairs[i + 1].data.map;
            var j: usize = 0;
            while (j + 1 < akvs.len) : (j += 2) {
                const ak = akvs[j].data;
                if (ak != .keyword or ak.keyword.ns != null) continue;
                if (std.mem.eql(u8, ak.keyword.name, "extra-paths")) {
                    alias.extra_paths = try collectStringVec(allocator, akvs[j + 1]);
                } else if (std.mem.eql(u8, ak.keyword.name, "extra-deps")) {
                    alias.extra_deps = try parseDeps(allocator, akvs[j + 1]);
                } else if (std.mem.eql(u8, ak.keyword.name, "main-opts")) {
                    alias.main_opts = try collectStringVec(allocator, akvs[j + 1]);
                } else if (std.mem.eql(u8, ak.keyword.name, "exec-fn")) {
                    alias.exec_fn = symbolName(allocator, akvs[j + 1]) catch null;
                } else if (std.mem.eql(u8, ak.keyword.name, "exec-args")) {
                    if (akvs[j + 1].data == .map) alias.exec_args = akvs[j + 1];
                }
            }
        }
        try out.append(allocator, alias);
    }
    return out.toOwnedSlice(allocator);
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
/// A `:mvn/version` key is recorded (`Dep.mvn_version`) for skip-at-resolve,
/// not rejected (source-only policy, ADR-0101 amendment).
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
            // Source-only policy: cljw cannot fetch a Maven/Clojars JAR. Record
            // the coord (skipped + summary-warned at resolve, ADR-0101 amendment)
            // instead of rejecting — a transitive `org.clojure/clojure` :mvn (cw
            // itself, in nearly every lib's deps.edn) must not abort resolution.
            dep.mvn_version = val orelse "";
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

/// Render a symbol form to its `"ns/name"` (or bare `"name"`) text — used for
/// `:exec-fn foo.bar/run`. Errors out (caller defaults to null) for a non-symbol.
fn symbolName(allocator: std.mem.Allocator, v: Form) ![]const u8 {
    return switch (v.data) {
        .symbol => |s| if (s.ns) |ns| try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, s.name }) else s.name,
        else => error.NotASymbol,
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
    const cfg = try parseDepsEdn(arena.allocator(), "{:deps {mono/lib {:git/url \"https://x\" :git/sha \"abc123\" :deps/root \"libs/core\"}}}");
    try testing.expectEqual(@as(usize, 1), cfg.deps.len);
    try testing.expectEqualStrings("https://x", cfg.deps[0].git_url.?);
    try testing.expectEqualStrings("abc123", cfg.deps[0].git_sha.?);
    try testing.expectEqualStrings("libs/core", cfg.deps[0].deps_root.?);
}

test "parse: :aliases extra-paths + extra-deps" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseDepsEdn(arena.allocator(), "{:aliases {:dev {:extra-paths [\"dev\"] :extra-deps {u/u {:local/root \"../u\"}}}}}");
    try testing.expectEqual(@as(usize, 1), cfg.aliases.len);
    try testing.expectEqualStrings("dev", cfg.aliases[0].name);
    try testing.expectEqualStrings("dev", cfg.aliases[0].extra_paths[0]);
    try testing.expectEqualStrings("../u", cfg.aliases[0].extra_deps[0].local_root.?);
}

test "parse: :aliases :main-opts + :exec-fn + :exec-args (D-309 run modes)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const cfg = try parseDepsEdn(arena.allocator(), "{:aliases {:run {:main-opts [\"-m\" \"my.app\"]} :build {:exec-fn foo.bar/release :exec-args {:id 5}}}}");
    try testing.expectEqual(@as(usize, 2), cfg.aliases.len);
    // :run — main-opts captured in order.
    try testing.expectEqualStrings("run", cfg.aliases[0].name);
    try testing.expectEqual(@as(usize, 2), cfg.aliases[0].main_opts.len);
    try testing.expectEqualStrings("-m", cfg.aliases[0].main_opts[0]);
    try testing.expectEqualStrings("my.app", cfg.aliases[0].main_opts[1]);
    // :build — exec-fn is the qualified "ns/name"; exec-args is the map Form.
    try testing.expectEqualStrings("build", cfg.aliases[1].name);
    try testing.expectEqualStrings("foo.bar/release", cfg.aliases[1].exec_fn.?);
    try testing.expect(cfg.aliases[1].exec_args != null);
    try testing.expect(cfg.aliases[1].exec_args.?.data == .map);
}

test "parse: :mvn/version is recorded + skipped, not rejected (ADR-0101 amendment)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Source-only policy: a :mvn dep parses (no error) with mvn_version set and
    // no source coord, so resolve skips it (the transitive org.clojure/clojure
    // case must not abort resolution).
    const cfg = try parseDepsEdn(arena.allocator(), "{:deps {x/y {:mvn/version \"1.0\"}}}");
    try testing.expectEqual(@as(usize, 1), cfg.deps.len);
    try testing.expectEqualStrings("1.0", cfg.deps[0].mvn_version.?);
    try testing.expect(cfg.deps[0].local_root == null);
    try testing.expect(cfg.deps[0].git_url == null);
}
