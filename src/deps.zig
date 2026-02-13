// Copyright (c) 2026 chaploud. All rights reserved.
// The use and distribution terms for this software are covered by the
// Eclipse Public License 1.0 (https://opensource.org/license/epl-1-0)
// which can be found in the file LICENSE at the root of this distribution.
// By using this software in any fashion, you are agreeing to be bound by
// the terms of this license.
// You must not remove this notice, or any other, from this software.

//! deps.edn parser for ClojureWasm.
//!
//! Parses deps.edn (EDN format) into a DepsConfig struct.
//! Uses the existing Reader for EDN parsing — no bootstrap needed.
//!
//! Supported keys:
//!   :paths          — source directories (vector of strings)
//!   :deps           — dependencies (map: symbol → dep-map)
//!   :aliases        — alias definitions (map: keyword → alias-map)
//!   :cljw/main      — main namespace (symbol)
//!   :cljw/test-paths — test directories (vector of strings)
//!   :cljw/wasm-deps — wasm module dependencies (map)
//!
//! Unsupported keys produce clear errors:
//!   :mvn/version    → "Maven dependencies not supported yet"
//!   :jvm-opts       → warning (ignored)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = @import("reader/reader.zig").Reader;
const Form = @import("reader/form.zig").Form;
const FormData = @import("reader/form.zig").FormData;

/// A single dependency declaration.
pub const Dep = struct {
    name: []const u8 = "", // lib name (e.g. "medley/medley")
    local_root: ?[]const u8 = null, // :local/root path
    git_url: ?[]const u8 = null, // :git/url
    git_sha: ?[]const u8 = null, // :git/sha
    git_tag: ?[]const u8 = null, // :git/tag (optional, for display + validation)
    deps_root: ?[]const u8 = null, // :deps/root (monorepo subdirectory)
};

/// A wasm module dependency: name → path.
pub const WasmDep = struct {
    name: []const u8,
    path: []const u8,
};

/// An alias definition.
pub const Alias = struct {
    extra_paths: []const []const u8 = &.{},
    extra_deps: []const Dep = &.{},
    main_opts: []const []const u8 = &.{}, // -M mode args
    exec_fn: ?[]const u8 = null, // -X mode: qualified fn name
    exec_args: []const ExecArg = &.{}, // -X mode: keyword args
    ns_default: ?[]const u8 = null, // default ns for unqualified -X fns
    ns_aliases: []const NsAlias = &.{}, // ns aliases for -X mode
};

/// A keyword argument for -X exec mode.
pub const ExecArg = struct {
    key: []const u8,
    value: []const u8, // string representation
};

/// A namespace alias mapping.
pub const NsAlias = struct {
    alias: []const u8,
    ns: []const u8,
};

/// Parsed deps.edn configuration.
pub const DepsConfig = struct {
    paths: []const []const u8 = &.{},
    deps: []const Dep = &.{},
    aliases: []const AliasEntry = &.{},
    // CW-specific keys (:cljw/* namespace)
    main_ns: ?[]const u8 = null,
    test_paths: []const []const u8 = &.{},
    wasm_deps: []const WasmDep = &.{},
    // Warnings/errors collected during parsing
    warnings: []const []const u8 = &.{},
};

/// Named alias entry (alias keyword name → Alias config).
pub const AliasEntry = struct {
    name: []const u8,
    alias: Alias,
};

/// Parse deps.edn source text into a DepsConfig.
pub fn parseDepsEdn(allocator: Allocator, source: []const u8) DepsConfig {
    var reader = Reader.init(allocator, source);
    const form = reader.read() catch return .{};
    const root = form orelse return .{};

    if (root.data != .map) return .{};
    return parseDepsEdnMap(allocator, root.data.map);
}

/// Parse the top-level map entries of a deps.edn file.
fn parseDepsEdnMap(allocator: Allocator, entries: []const Form) DepsConfig {
    var config = DepsConfig{};
    var warnings = std.ArrayList([]const u8).empty;

    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const kw = entries[i].data.keyword;

        if (kw.ns == null) {
            // Unqualified keys: :paths, :deps, :aliases
            if (std.mem.eql(u8, kw.name, "paths")) {
                config.paths = parseStringVector(allocator, entries[i + 1]);
            } else if (std.mem.eql(u8, kw.name, "deps")) {
                config.deps = parseDepsMap(allocator, entries[i + 1]);
            } else if (std.mem.eql(u8, kw.name, "aliases")) {
                config.aliases = parseAliasesMap(allocator, entries[i + 1]);
            }
        } else if (std.mem.eql(u8, kw.ns.?, "cljw")) {
            // CW-specific keys: :cljw/main, :cljw/test-paths, :cljw/wasm-deps
            if (std.mem.eql(u8, kw.name, "main")) {
                config.main_ns = parseSymbolName(allocator, entries[i + 1]);
            } else if (std.mem.eql(u8, kw.name, "test-paths")) {
                config.test_paths = parseStringVector(allocator, entries[i + 1]);
            } else if (std.mem.eql(u8, kw.name, "wasm-deps")) {
                config.wasm_deps = parseWasmDepsMap(allocator, entries[i + 1]);
            }
        }

        // Detect unsupported keys and generate warnings
        checkUnsupportedKeys(allocator, &warnings, entries[i]);
    }

    if (warnings.items.len > 0) {
        config.warnings = warnings.toOwnedSlice(allocator) catch &.{};
    }

    return config;
}

// --- Helper parsers ---

/// Extract a vector of strings from a Form.
fn parseStringVector(allocator: Allocator, form: Form) []const []const u8 {
    if (form.data != .vector) return &.{};
    const vec = form.data.vector;
    const paths = allocator.alloc([]const u8, vec.len) catch return &.{};
    var count: usize = 0;
    for (vec) |elem| {
        if (elem.data == .string) {
            paths[count] = elem.data.string;
            count += 1;
        }
    }
    return paths[0..count];
}

/// Parse a symbol Form into a dotted namespace string.
/// my-app/core → "my-app.core", my-app.core → "my-app.core"
fn parseSymbolName(allocator: Allocator, form: Form) ?[]const u8 {
    if (form.data != .symbol) return null;
    const sym = form.data.symbol;
    if (sym.ns) |ns| {
        return std.fmt.allocPrint(allocator, "{s}.{s}", .{ ns, sym.name }) catch null;
    }
    return sym.name;
}

/// Parse a qualified function name, preserving ns/name format.
/// my-app.build/release → "my-app.build/release", release → "release"
fn parseQualifiedFnName(allocator: Allocator, form: Form) ?[]const u8 {
    if (form.data != .symbol) return null;
    const sym = form.data.symbol;
    if (sym.ns) |ns| {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, sym.name }) catch null;
    }
    return sym.name;
}

/// Parse :deps map: {lib-sym dep-map, ...}
fn parseDepsMap(allocator: Allocator, form: Form) []const Dep {
    if (form.data != .map) return &.{};
    const entries = form.data.map;
    const count = entries.len / 2;
    if (count == 0) return &.{};
    const deps = allocator.alloc(Dep, count) catch return &.{};
    var n: usize = 0;

    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        // key: symbol (lib name)
        const lib_name = formatLibName(allocator, entries[i]) orelse continue;
        // value: map with :local/root, :git/url, :git/sha, etc.
        if (entries[i + 1].data != .map) continue;
        var dep = parseDepMap(entries[i + 1].data.map);
        dep.name = lib_name;
        deps[n] = dep;
        n += 1;
    }
    return deps[0..n];
}

/// Format a library name from a symbol Form.
/// medley/medley → "medley/medley", io.github.user/repo → "io.github.user/repo"
fn formatLibName(allocator: Allocator, form: Form) ?[]const u8 {
    if (form.data != .symbol) return null;
    const sym = form.data.symbol;
    if (sym.ns) |ns| {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, sym.name }) catch null;
    }
    return sym.name;
}

/// Parse a single dependency map: {:local/root "path"} or {:git/url "..." :git/sha "..."}
fn parseDepMap(entries: []const Form) Dep {
    var dep = Dep{};
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const dk = entries[i].data.keyword;
        const ns = dk.ns orelse continue;

        if (entries[i + 1].data == .string) {
            const val = entries[i + 1].data.string;
            if (std.mem.eql(u8, ns, "local") and std.mem.eql(u8, dk.name, "root")) {
                dep.local_root = val;
            } else if (std.mem.eql(u8, ns, "git")) {
                if (std.mem.eql(u8, dk.name, "url")) {
                    dep.git_url = val;
                } else if (std.mem.eql(u8, dk.name, "sha")) {
                    dep.git_sha = val;
                } else if (std.mem.eql(u8, dk.name, "tag")) {
                    dep.git_tag = val;
                }
            } else if (std.mem.eql(u8, ns, "deps") and std.mem.eql(u8, dk.name, "root")) {
                dep.deps_root = val;
            }
        }
    }
    return dep;
}

/// Parse :aliases map: {:dev alias-map, :test alias-map, ...}
fn parseAliasesMap(allocator: Allocator, form: Form) []const AliasEntry {
    if (form.data != .map) return &.{};
    const entries = form.data.map;
    const count = entries.len / 2;
    if (count == 0) return &.{};
    const alias_entries = allocator.alloc(AliasEntry, count) catch return &.{};
    var n: usize = 0;

    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        // key: keyword (alias name)
        if (entries[i].data != .keyword) continue;
        const alias_name = entries[i].data.keyword.name;
        // value: map with :extra-paths, :extra-deps, :main-opts, :exec-fn, :exec-args
        if (entries[i + 1].data != .map) continue;
        alias_entries[n] = .{
            .name = alias_name,
            .alias = parseAliasMap(allocator, entries[i + 1].data.map),
        };
        n += 1;
    }
    return alias_entries[0..n];
}

/// Parse a single alias map: {:extra-paths [...], :extra-deps {...}, ...}
fn parseAliasMap(allocator: Allocator, entries: []const Form) Alias {
    var alias = Alias{};
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const kw = entries[i].data.keyword;
        if (kw.ns != null) continue; // alias keys are unqualified

        if (std.mem.eql(u8, kw.name, "extra-paths")) {
            alias.extra_paths = parseStringVector(allocator, entries[i + 1]);
        } else if (std.mem.eql(u8, kw.name, "extra-deps")) {
            alias.extra_deps = parseDepsMap(allocator, entries[i + 1]);
        } else if (std.mem.eql(u8, kw.name, "main-opts")) {
            alias.main_opts = parseStringVector(allocator, entries[i + 1]);
        } else if (std.mem.eql(u8, kw.name, "exec-fn")) {
            alias.exec_fn = parseQualifiedFnName(allocator, entries[i + 1]);
        } else if (std.mem.eql(u8, kw.name, "exec-args")) {
            alias.exec_args = parseExecArgs(allocator, entries[i + 1]);
        } else if (std.mem.eql(u8, kw.name, "ns-default")) {
            alias.ns_default = parseSymbolName(allocator, entries[i + 1]);
        }
    }
    return alias;
}

/// Parse :exec-args map: {:key "value", ...}
fn parseExecArgs(allocator: Allocator, form: Form) []const ExecArg {
    if (form.data != .map) return &.{};
    const entries = form.data.map;
    const count = entries.len / 2;
    if (count == 0) return &.{};
    const args = allocator.alloc(ExecArg, count) catch return &.{};
    var n: usize = 0;

    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const key = entries[i].data.keyword.name;
        // Store value as string representation
        const value = formToString(allocator, entries[i + 1]) orelse continue;
        args[n] = .{ .key = key, .value = value };
        n += 1;
    }
    return args[0..n];
}

/// Convert a Form to its string representation (for exec-args).
fn formToString(allocator: Allocator, form: Form) ?[]const u8 {
    return switch (form.data) {
        .string => |s| s,
        .integer => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch null,
        .float => |v| std.fmt.allocPrint(allocator, "{d}", .{v}) catch null,
        .boolean => |v| if (v) "true" else "false",
        .nil => "nil",
        .symbol => |s| if (s.ns) |ns|
            std.fmt.allocPrint(allocator, "{s}/{s}", .{ ns, s.name }) catch null
        else
            s.name,
        .keyword => |k| if (k.ns) |ns|
            std.fmt.allocPrint(allocator, ":{s}/{s}", .{ ns, k.name }) catch null
        else
            std.fmt.allocPrint(allocator, ":{s}", .{k.name}) catch null,
        else => null,
    };
}

/// Parse :cljw/wasm-deps map: {"name" {:path "file.wasm"}, ...}
fn parseWasmDepsMap(allocator: Allocator, form: Form) []const WasmDep {
    if (form.data != .map) return &.{};
    const entries = form.data.map;
    const count = entries.len / 2;
    if (count == 0) return &.{};
    const deps = allocator.alloc(WasmDep, count) catch return &.{};
    var n: usize = 0;

    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .string) continue;
        const name = entries[i].data.string;
        if (entries[i + 1].data != .map) continue;
        // Look for :path or :local/root in value map
        const path = extractWasmPath(entries[i + 1].data.map) orelse continue;
        deps[n] = .{ .name = name, .path = path };
        n += 1;
    }
    return deps[0..n];
}

/// Extract wasm path from dep map (supports :path and :local/root).
fn extractWasmPath(entries: []const Form) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < entries.len) : (i += 2) {
        if (entries[i].data != .keyword) continue;
        const kw = entries[i].data.keyword;
        if (entries[i + 1].data != .string) continue;
        // :path "file.wasm"
        if (kw.ns == null and std.mem.eql(u8, kw.name, "path")) {
            return entries[i + 1].data.string;
        }
        // :local/root "file.wasm" (legacy compat)
        if (kw.ns != null and std.mem.eql(u8, kw.ns.?, "local") and std.mem.eql(u8, kw.name, "root")) {
            return entries[i + 1].data.string;
        }
    }
    return null;
}

/// Check for unsupported keys and add warnings.
fn checkUnsupportedKeys(allocator: Allocator, warnings: *std.ArrayList([]const u8), key_form: Form) void {
    if (key_form.data != .keyword) return;
    const kw = key_form.data.keyword;

    // :jvm-opts → warning
    if (kw.ns == null and std.mem.eql(u8, kw.name, "jvm-opts")) {
        const msg = std.fmt.allocPrint(allocator, "WARNING: :jvm-opts ignored — ClojureWasm is not a JVM runtime.", .{}) catch return;
        warnings.append(allocator, msg) catch {};
    }
    // :mvn/repos, :mvn/local-repo → warning
    if (kw.ns != null and std.mem.eql(u8, kw.ns.?, "mvn")) {
        const msg = std.fmt.allocPrint(allocator, "WARNING: :{s}/{s} not supported — ClojureWasm uses its own cache.", .{ kw.ns.?, kw.name }) catch return;
        warnings.append(allocator, msg) catch {};
    }
}

/// Check if a dep uses unsupported Maven coordinates and return an error message.
pub fn checkDepForMaven(allocator: Allocator, dep_entries: []const Form) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < dep_entries.len) : (i += 2) {
        if (dep_entries[i].data != .keyword) continue;
        const kw = dep_entries[i].data.keyword;
        const ns = kw.ns orelse continue;
        if (std.mem.eql(u8, ns, "mvn") and std.mem.eql(u8, kw.name, "version")) {
            if (dep_entries[i + 1].data == .string) {
                return std.fmt.allocPrint(
                    allocator,
                    "Maven dependency not supported: {{:mvn/version \"{s}\"}}. Use :git/url + :git/sha instead.",
                    .{dep_entries[i + 1].data.string},
                ) catch null;
            }
        }
    }
    return null;
}

/// Resolve io.github.* / io.gitlab.* library names to Git URLs.
/// io.github.user/repo → "https://github.com/user/repo"
/// io.gitlab.user/repo → "https://gitlab.com/user/repo"
pub fn inferGitUrl(allocator: Allocator, lib_name: []const u8) ?[]const u8 {
    // Split on "/"
    const slash_idx = std.mem.indexOf(u8, lib_name, "/") orelse return null;
    const group = lib_name[0..slash_idx];
    const repo = lib_name[slash_idx + 1 ..];

    if (std.mem.startsWith(u8, group, "io.github.")) {
        const user = group["io.github.".len..];
        return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}", .{ user, repo }) catch null;
    }
    if (std.mem.startsWith(u8, group, "io.gitlab.")) {
        const user = group["io.gitlab.".len..];
        return std.fmt.allocPrint(allocator, "https://gitlab.com/{s}/{s}", .{ user, repo }) catch null;
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

// Helper: parse deps.edn using an arena allocator (mirrors production usage).
fn testParseDepsEdn(source: []const u8) struct { config: DepsConfig, arena: std.heap.ArenaAllocator } {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    const config = parseDepsEdn(arena.allocator(), source);
    return .{ .config = config, .arena = arena };
}

test "parseDepsEdn: empty map" {
    var state = testParseDepsEdn("{}");
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 0), config.paths.len);
    try std.testing.expectEqual(@as(usize, 0), config.deps.len);
    try std.testing.expectEqual(@as(usize, 0), config.aliases.len);
    try std.testing.expect(config.main_ns == null);
}

test "parseDepsEdn: paths only" {
    var state = testParseDepsEdn("{:paths [\"src\" \"resources\"]}");
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 2), config.paths.len);
    try std.testing.expectEqualStrings("src", config.paths[0]);
    try std.testing.expectEqualStrings("resources", config.paths[1]);
}

test "parseDepsEdn: local dep" {
    var state = testParseDepsEdn(
        \\{:deps {my-utils/my-utils {:local/root "../my-utils"}}}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 1), config.deps.len);
    try std.testing.expectEqualStrings("my-utils/my-utils", config.deps[0].name);
    try std.testing.expectEqualStrings("../my-utils", config.deps[0].local_root.?);
    try std.testing.expect(config.deps[0].git_url == null);
}

test "parseDepsEdn: git dep with tag" {
    var state = testParseDepsEdn(
        \\{:deps {medley/medley {:git/url "https://github.com/weavejester/medley"
        \\                       :git/tag "1.8.0" :git/sha "a1b2c3d"}}}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 1), config.deps.len);
    try std.testing.expectEqualStrings("medley/medley", config.deps[0].name);
    try std.testing.expectEqualStrings("https://github.com/weavejester/medley", config.deps[0].git_url.?);
    try std.testing.expectEqualStrings("a1b2c3d", config.deps[0].git_sha.?);
    try std.testing.expectEqualStrings("1.8.0", config.deps[0].git_tag.?);
}

test "parseDepsEdn: deps/root" {
    var state = testParseDepsEdn(
        \\{:deps {mono/lib {:git/url "https://github.com/user/mono"
        \\                   :git/sha "abc123" :deps/root "libs/core"}}}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 1), config.deps.len);
    try std.testing.expectEqualStrings("libs/core", config.deps[0].deps_root.?);
}

test "parseDepsEdn: cljw-specific keys" {
    var state = testParseDepsEdn(
        \\{:paths ["src"]
        \\ :cljw/main my-app.core
        \\ :cljw/test-paths ["test" "test-integration"]}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 1), config.paths.len);
    try std.testing.expectEqualStrings("src", config.paths[0]);
    try std.testing.expectEqualStrings("my-app.core", config.main_ns.?);
    try std.testing.expectEqual(@as(usize, 2), config.test_paths.len);
    try std.testing.expectEqualStrings("test", config.test_paths[0]);
}

test "parseDepsEdn: aliases" {
    var state = testParseDepsEdn(
        \\{:aliases {:dev {:extra-paths ["dev" "resources"]
        \\                 :main-opts ["-m" "my-app.dev"]}
        \\           :build {:exec-fn my-app.build/release
        \\                   :exec-args {:target "native"}}}}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 2), config.aliases.len);

    // :dev alias
    const dev = config.aliases[0];
    try std.testing.expectEqualStrings("dev", dev.name);
    try std.testing.expectEqual(@as(usize, 2), dev.alias.extra_paths.len);
    try std.testing.expectEqualStrings("dev", dev.alias.extra_paths[0]);
    try std.testing.expectEqualStrings("resources", dev.alias.extra_paths[1]);
    try std.testing.expectEqual(@as(usize, 2), dev.alias.main_opts.len);
    try std.testing.expectEqualStrings("-m", dev.alias.main_opts[0]);
    try std.testing.expectEqualStrings("my-app.dev", dev.alias.main_opts[1]);

    // :build alias
    const build = config.aliases[1];
    try std.testing.expectEqualStrings("build", build.name);
    try std.testing.expectEqualStrings("my-app.build/release", build.alias.exec_fn.?);
    try std.testing.expectEqual(@as(usize, 1), build.alias.exec_args.len);
    try std.testing.expectEqualStrings("target", build.alias.exec_args[0].key);
    try std.testing.expectEqualStrings("native", build.alias.exec_args[0].value);
}

test "parseDepsEdn: jvm-opts warning" {
    var state = testParseDepsEdn(
        \\{:paths ["src"] :jvm-opts ["-Xmx2g"]}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expect(config.warnings.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, config.warnings[0], "jvm-opts") != null);
}

test "parseDepsEdn: wasm deps" {
    var state = testParseDepsEdn(
        \\{:cljw/wasm-deps {"math" {:path "wasm/math.wasm"}
        \\                   "crypto" {:local/root "wasm/crypto.wasm"}}}
    );
    defer state.arena.deinit();
    const config = state.config;
    try std.testing.expectEqual(@as(usize, 2), config.wasm_deps.len);
    try std.testing.expectEqualStrings("math", config.wasm_deps[0].name);
    try std.testing.expectEqualStrings("wasm/math.wasm", config.wasm_deps[0].path);
    try std.testing.expectEqualStrings("crypto", config.wasm_deps[1].name);
    try std.testing.expectEqualStrings("wasm/crypto.wasm", config.wasm_deps[1].path);
}

test "parseDepsEdn: invalid source" {
    // Non-map root
    var s1 = testParseDepsEdn("[1 2 3]");
    defer s1.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), s1.config.paths.len);

    // Empty string
    var s2 = testParseDepsEdn("");
    defer s2.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), s2.config.paths.len);

    // Invalid EDN
    var s3 = testParseDepsEdn("{:paths");
    defer s3.arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), s3.config.paths.len);
}

test "inferGitUrl: io.github pattern" {
    const url = inferGitUrl(std.testing.allocator, "io.github.weavejester/medley");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://github.com/weavejester/medley", url.?);
    std.testing.allocator.free(url.?);
}

test "inferGitUrl: io.gitlab pattern" {
    const url = inferGitUrl(std.testing.allocator, "io.gitlab.user/repo");
    try std.testing.expect(url != null);
    try std.testing.expectEqualStrings("https://gitlab.com/user/repo", url.?);
    std.testing.allocator.free(url.?);
}

test "inferGitUrl: non-matching pattern" {
    try std.testing.expect(inferGitUrl(std.testing.allocator, "medley/medley") == null);
    try std.testing.expect(inferGitUrl(std.testing.allocator, "no-slash") == null);
}

test "parseDepsEdn: full realistic example" {
    var state = testParseDepsEdn(
        \\{:paths ["src"]
        \\ :deps {medley/medley {:git/url "https://github.com/weavejester/medley"
        \\                       :git/tag "1.8.0" :git/sha "a1b2c3d"}
        \\        my-utils/my-utils {:local/root "../shared-utils"}}
        \\ :cljw/main my-app.core
        \\ :cljw/test-paths ["test"]
        \\ :aliases {:dev {:extra-paths ["dev" "resources"]
        \\                 :extra-deps {my/dev-tools {:local/root "../dev-tools"}}
        \\                 :main-opts ["-m" "my-app.dev"]}
        \\           :test {:extra-deps {my/test-utils {:local/root "../test-utils"}}}
        \\           :build {:exec-fn my-app.build/release
        \\                   :exec-args {:target "native"}}}}
    );
    defer state.arena.deinit();
    const config = state.config;

    // Paths
    try std.testing.expectEqual(@as(usize, 1), config.paths.len);
    try std.testing.expectEqualStrings("src", config.paths[0]);

    // Deps
    try std.testing.expectEqual(@as(usize, 2), config.deps.len);

    // Main
    try std.testing.expectEqualStrings("my-app.core", config.main_ns.?);

    // Test paths
    try std.testing.expectEqual(@as(usize, 1), config.test_paths.len);

    // Aliases
    try std.testing.expectEqual(@as(usize, 3), config.aliases.len);

    // :dev alias has extra-deps
    const dev = config.aliases[0];
    try std.testing.expectEqualStrings("dev", dev.name);
    try std.testing.expectEqual(@as(usize, 1), dev.alias.extra_deps.len);
    try std.testing.expectEqualStrings("my/dev-tools", dev.alias.extra_deps[0].name);
}

test "checkDepForMaven" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var reader = Reader.init(alloc, "{:mvn/version \"1.2.3\"}");
    const form = try reader.read();
    const root = form.?;
    const msg = checkDepForMaven(alloc, root.data.map);
    try std.testing.expect(msg != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.?, "Maven") != null);
}
