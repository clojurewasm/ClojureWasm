// SPDX-License-Identifier: EPL-2.0
//! Filesystem + chained require resolvers (ADR-0084, D-158).
//!
//! `filesystemResolver` maps a namespace symbol to a `.clj`/`.cljc` file on the
//! `rt.load_paths` classpath (`foo.bar-baz` → `foo/bar_baz.clj`, JVM munge) and
//! reads its source. `chainedResolver` tries the bootstrap-embedded resolver
//! FIRST (so clojure.core / clojure.test can never be shadowed by a stray
//! on-disk file), then the filesystem. The CLI installs `chainedResolver` for
//! `cljw run` / REPL; the test/embedded path keeps `embeddedResolver` so a stray
//! `.clj` in a test's cwd cannot perturb a unit/diff test.
//!
//! Backend: impl-only (filesystem read + ns→path munge)
//! Impl deps: file_io
//! Clojure peer: none (this is the require machinery, not a var)

const std = @import("std");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const ResolvedSource = @import("../runtime/runtime.zig").ResolvedSource;
const file_io = @import("../runtime/file_io.zig");
const error_catalog = @import("../runtime/error/catalog.zig");
const bootstrap = @import("bootstrap.zig");

/// Munge a namespace name into its relative resource path: `.` → `/`, `-` → `_`
/// (JVM `clojure.lang.RT/resourceName` convention). Allocated in `arena`.
fn mungeNsToPath(arena: std.mem.Allocator, ns_name: []const u8) ![]u8 {
    const buf = try arena.alloc(u8, ns_name.len);
    for (ns_name, 0..) |c, i| buf[i] = switch (c) {
        '.' => '/',
        '-' => '_',
        else => c,
    };
    return buf;
}

/// Resolve `ns_name` to source by searching `rt.load_paths` for
/// `<dir>/<munged>.clj` then `.cljc`. Returns null when no file is found (so the
/// chain / caller maps to `lib_not_found`); raises `lib_load_failed` when a file
/// exists but cannot be read. Source + label live in `rt.load_arena`.
pub fn filesystemResolver(rt: *Runtime, ns_name: []const u8) anyerror!?ResolvedSource {
    const arena = rt.load_arena.allocator();
    const rel = try mungeNsToPath(arena, ns_name);
    const exts = [_][]const u8{ ".clj", ".cljc" };
    for (rt.load_paths) |dir| {
        for (exts) |ext| {
            const path = try std.fmt.allocPrint(arena, "{s}/{s}{s}", .{ dir, rel, ext });
            const src = file_io.readAll(rt.io, arena, path) catch |err| switch (err) {
                // Not at this dir/ext — keep searching.
                error.FileNotFound, error.NotDir, error.BadPathName => continue,
                // Found but unreadable (permissions, I/O) — distinct from "not found".
                else => return error_catalog.raise(.lib_load_failed, .{}, .{
                    .ns = ns_name,
                    .detail = @errorName(err),
                }),
            };
            return .{ .source = src, .label = path };
        }
    }
    return null;
}

/// Embedded-FIRST chain: bootstrap nses (clojure.core/test/…) win, then the
/// filesystem. Installed by the CLI for `run` / REPL.
pub fn chainedResolver(rt: *Runtime, ns_name: []const u8) anyerror!?ResolvedSource {
    if (try bootstrap.embeddedResolver(rt, ns_name)) |r| return r;
    return filesystemResolver(rt, ns_name);
}

/// Install the embedded-first chain onto `rt.require_resolver`.
pub fn installChained(rt: *Runtime) void {
    rt.require_resolver = chainedResolver;
}

const testing = std.testing;

test "mungeNsToPath maps . to / and - to _" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("foo/bar_baz", try mungeNsToPath(a, "foo.bar-baz"));
    try testing.expectEqualStrings("clojure/string", try mungeNsToPath(a, "clojure.string"));
    try testing.expectEqualStrings("a", try mungeNsToPath(a, "a"));
    try testing.expectEqualStrings("my_app/core_test", try mungeNsToPath(a, "my-app.core-test"));
}
