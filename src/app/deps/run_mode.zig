// SPDX-License-Identifier: EPL-2.0
//! deps.edn run modes `-M` / `-X` (Convergence Campaign Stage 1.4 / D-309).
//!
//! `-A` resolves a classpath only; `-M` and `-X` additionally *run* something:
//!   - `-M[:aliases] [main-opts…]` runs the `clojure.main` mini-grammar — the
//!     selected alias's `:main-opts` with the user's trailing args APPENDED
//!     (clj append-not-replace). Supported main-opts: `-m ns [args…]`
//!     (`requiring-resolve` the ns + `(-main args…)`), `-e expr` (eval+print),
//!     a bare `file.clj [args…]` (load the script), and `-h`.
//!   - `-X[:aliases] [ns/fn] [:k v…]` invokes a single `:exec-fn` with one map:
//!     the alias's `:exec-args` merged under CLI `:key value` pairs (CLI wins,
//!     values EDN-read), `(exec-fn merged-map)`.
//!
//! cljw is JVM-less and single-process: there is no second `clojure.main` to
//! exec into, so the combined launcher + main grammar runs in this one process
//! (the cw v0 shape). The run is synthesized into a Clojure source string and
//! handed to `runner.runSource` with `print_results=false` — `clojure.main`
//! never prints a `-main` / `:exec-fn` result (only `-e` prints, handled by the
//! standalone-`-e` branch). See `private/notes/stage14-deps-run-mode-survey.md`
//! for the grammar + the three v0 gaps this module fixes (args reach `-main`;
//! append semantics; EDN value coercion).

const std = @import("std");
const parse = @import("parse.zig");
const runner = @import("../runner.zig");
const form_mod = @import("../../eval/form.zig");

pub const Mode = enum { main, exec };

/// Run a `-M` / `-X` invocation. `cfg` is the parsed deps.edn (its aliases
/// supply `:main-opts` / `:exec-fn` / `:exec-args`); `alias_names` are the
/// `-M:a:b` selections; `run_args` are the tokens after the `-M`/`-X` flag;
/// `load_paths` is the already-resolved classpath. Errors render against the
/// synthesized source like any eval error.
pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    mode: Mode,
    cfg: parse.DepsConfig,
    alias_names: []const []const u8,
    run_args: []const []const u8,
    load_paths: []const []const u8,
) !void {
    switch (mode) {
        .main => try runMain(io, gpa, arena, stdout, stderr, cfg, alias_names, run_args, load_paths),
        .exec => try runExec(io, gpa, arena, stdout, stderr, cfg, alias_names, run_args, load_paths),
    }
}

// --- -M (clojure.main mini-grammar) ---

fn runMain(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    cfg: parse.DepsConfig,
    alias_names: []const []const u8,
    run_args: []const []const u8,
    load_paths: []const []const u8,
) !void {
    // Effective opts = alias :main-opts (last selected alias wins) ++ user args.
    const alias_opts = lastAliasMainOpts(cfg, alias_names);
    var opts: std.ArrayList([]const u8) = .empty;
    try opts.appendSlice(arena, alias_opts);
    try opts.appendSlice(arena, run_args);
    const eff = opts.items;

    if (eff.len == 0) {
        try stderr.writeAll("-M requires a main option: -m <ns>, a script file, or -e <expr>\n");
        try stderr.flush();
        std.process.exit(1);
    }

    const head = eff[0];
    if (std.mem.eql(u8, head, "-m") or std.mem.eql(u8, head, "--main")) {
        if (eff.len < 2) {
            try stderr.writeAll("-m requires a namespace argument\n");
            try stderr.flush();
            std.process.exit(1);
        }
        const ns = eff[1];
        const src = try synthMainNs(arena, ns, eff[2..]);
        try runner.runSource(io, gpa, arena, stdout, stderr, src, "<-M>", load_paths, false);
    } else if (std.mem.eql(u8, head, "-e") or std.mem.eql(u8, head, "--eval")) {
        if (eff.len < 2) {
            try stderr.writeAll("-e requires an expression argument\n");
            try stderr.flush();
            std.process.exit(1);
        }
        // Standalone -e: print non-nil results, matching `cljw -e`.
        try runner.runSource(io, gpa, arena, stdout, stderr, eff[1], "<-e>", load_paths, true);
    } else if (std.mem.eql(u8, head, "-h") or std.mem.eql(u8, head, "--help") or std.mem.eql(u8, head, "-?")) {
        try stdout.writeAll(
            \\Usage under -M: cljw -M[:aliases] <main-opt> [args]
            \\  -m, --main <ns>   require <ns>, then call (<ns>/-main args…)
            \\  -e, --eval <expr> eval <expr>, print each non-nil result
            \\  <file.clj>        load the script file
            \\
        );
        try stdout.flush();
    } else if (std.mem.startsWith(u8, head, "-")) {
        try stderr.print("-M: unrecognised main option '{s}'\n", .{head});
        try stderr.flush();
        std.process.exit(1);
    } else {
        // Bare token → a script file path. Load it (no result printing, the
        // clojure.main script contract). Trailing args are not bound to
        // *command-line-args* yet (D-310).
        const file = std.Io.Dir.cwd().openFile(io, head, .{}) catch |err| {
            try stderr.print("-M: cannot open script '{s}': {s}\n", .{ head, @errorName(err) });
            try stderr.flush();
            std.process.exit(1);
        };
        defer file.close(io);
        var file_buf: [4096]u8 = undefined;
        var file_reader = file.reader(io, &file_buf);
        const file_src = try file_reader.interface.allocRemaining(arena, .unlimited);
        try runner.runSource(io, gpa, arena, stdout, stderr, file_src, head, load_paths, false);
    }
}

/// `(let [v (requiring-resolve 'ns/-main)] (if v (v "a" "b") (throw …)))`.
/// The guard turns a missing `-main` into a clean message rather than a bare
/// resolve failure (survey edge case 2).
fn synthMainNs(arena: std.mem.Allocator, ns: []const u8, args: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print(
        "(clojure.core/let [__cljw_main (clojure.core/requiring-resolve (quote {s}/-main))]" ++
            " (if __cljw_main (__cljw_main",
        .{ns},
    );
    for (args) |a| {
        try w.writeByte(' ');
        try writeStringLiteral(w, a);
    }
    try w.print(
        ") (throw (clojure.core/ex-info \"Namespace {s} has no -main fn\" {{}}))))",
        .{ns},
    );
    return aw.toOwnedSlice();
}

// --- -X (exec-fn) ---

fn runExec(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    cfg: parse.DepsConfig,
    alias_names: []const []const u8,
    run_args: []const []const u8,
    load_paths: []const []const u8,
) !void {
    // A leading non-`:` token overrides the alias's :exec-fn; the rest are
    // `:key value` overrides merged over :exec-args (CLI wins per-key).
    var kv_start: usize = 0;
    var exec_fn: ?[]const u8 = lastAliasExecFn(cfg, alias_names);
    if (run_args.len > 0 and !std.mem.startsWith(u8, run_args[0], ":")) {
        exec_fn = run_args[0];
        kv_start = 1;
    }
    const fn_sym = exec_fn orelse {
        try stderr.writeAll("-X requires an :exec-fn (in the alias) or a trailing ns/fn symbol\n");
        try stderr.flush();
        std.process.exit(1);
    };
    if (std.mem.findScalar(u8, fn_sym, '/') == null) {
        try stderr.print("-X: exec-fn '{s}' must be a qualified ns/fn symbol\n", .{fn_sym});
        try stderr.flush();
        std.process.exit(1);
    }

    const src = try synthExec(arena, fn_sym, lastAliasExecArgs(cfg, alias_names), run_args[kv_start..]);
    try runner.runSource(io, gpa, arena, stdout, stderr, src, "<-X>", load_paths, false);
}

/// `(let [f (requiring-resolve 'ns/fn)] (if f (f (merge ALIAS_ARGS {CLI})) (throw …)))`.
/// ALIAS_ARGS is the alias's `:exec-args` re-serialized (or `{}`); the CLI map's
/// values are spliced verbatim so EDN tokens keep their type (`:n 5` → long 5,
/// not "5" — the v0 string-coercion gap).
fn synthExec(arena: std.mem.Allocator, fn_sym: []const u8, exec_args: ?form_mod.Form, kvs: []const []const u8) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    // writeAll for the brace-heavy literals (Zig's format parser treats a bare
    // `{`/`}` as a placeholder); print only where a `{s}` substitution is needed.
    try w.writeAll("(clojure.core/let [__cljw_fn (clojure.core/requiring-resolve (quote ");
    try w.writeAll(fn_sym);
    // Both maps are QUOTED: `-X` args are EDN *data*, never evaluated, so a
    // symbol/list value stays a literal (clj semantics) instead of being
    // resolved/called. Self-evaluating values (int/bool/keyword/string) are
    // unaffected; the quote is what makes a bare-symbol value not error.
    try w.writeAll("))] (if __cljw_fn (__cljw_fn (clojure.core/merge (quote ");
    if (exec_args) |ea| try ea.formatPrStr(w) else try w.writeAll("{}");
    try w.writeAll(") (quote {");
    var i: usize = 0;
    while (i + 1 < kvs.len) : (i += 2) {
        if (i != 0) try w.writeByte(' ');
        // Key + value are EDN tokens from argv, spliced verbatim so a keyword
        // key stays a keyword and a numeric/boolean value keeps its type.
        try w.writeAll(kvs[i]);
        try w.writeByte(' ');
        try w.writeAll(kvs[i + 1]);
    }
    try w.writeAll("}))) (throw (clojure.core/ex-info \"Cannot resolve exec-fn ");
    try w.writeAll(fn_sym);
    try w.writeAll("\" {}))))");
    return aw.toOwnedSlice();
}

// --- helpers ---

fn lastAliasMainOpts(cfg: parse.DepsConfig, alias_names: []const []const u8) []const []const u8 {
    var out: []const []const u8 = &.{};
    for (alias_names) |name| {
        if (findAlias(cfg, name)) |al| if (al.main_opts.len > 0) {
            out = al.main_opts;
        };
    }
    return out;
}

fn lastAliasExecFn(cfg: parse.DepsConfig, alias_names: []const []const u8) ?[]const u8 {
    var out: ?[]const u8 = null;
    for (alias_names) |name| {
        if (findAlias(cfg, name)) |al| if (al.exec_fn) |f| {
            out = f;
        };
    }
    return out;
}

fn lastAliasExecArgs(cfg: parse.DepsConfig, alias_names: []const []const u8) ?form_mod.Form {
    var out: ?form_mod.Form = null;
    for (alias_names) |name| {
        if (findAlias(cfg, name)) |al| if (al.exec_args) |a| {
            out = a;
        };
    }
    return out;
}

fn findAlias(cfg: parse.DepsConfig, name: []const u8) ?parse.Alias {
    for (cfg.aliases) |a| if (std.mem.eql(u8, a.name, name)) return a;
    return null;
}

/// Write `s` as a Clojure string literal (double-quoted, `\`/`"` escaped).
fn writeStringLiteral(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

test "synthMainNs: ns + args → requiring-resolve guarded -main call" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = try synthMainNs(arena.allocator(), "my.app", &.{ "alpha", "be\"ta" });
    try testing.expect(std.mem.find(u8, src, "(quote my.app/-main)") != null);
    try testing.expect(std.mem.find(u8, src, "\"alpha\"") != null);
    // The embedded quote is escaped.
    try testing.expect(std.mem.find(u8, src, "be\\\"ta") != null);
    try testing.expect(std.mem.find(u8, src, "has no -main fn") != null);
}

test "synthExec: exec-fn + CLI kv splices values verbatim (EDN-typed)" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = try synthExec(arena.allocator(), "foo.bar/run", null, &.{ ":n", "5", ":on", "true" });
    try testing.expect(std.mem.find(u8, src, "(quote foo.bar/run)") != null);
    // Verbatim splice → 5 stays a long literal, not "5".
    try testing.expect(std.mem.find(u8, src, ":n 5") != null);
    try testing.expect(std.mem.find(u8, src, ":on true") != null);
    try testing.expect(std.mem.find(u8, src, "(clojure.core/merge (quote {}) (quote {") != null);
}
