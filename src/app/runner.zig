// SPDX-License-Identifier: EPL-2.0
//! Source-runner for `cljw` — the read/analyse/eval/print loop +
//! the surrounding Runtime / Env / backend / bootstrap setup. Called
//! by `app/cli.zig::dispatch` once it has resolved `source_text` from
//! one of `-e <expr>` / `<file.clj>` / `-` (stdin).
//!
//! This body was extracted from `src/main.zig` (D-031) so the
//! entry point shrinks to a thin argv-dispatcher. The function is
//! intentionally allocator-explicit (`io` / `gpa` / `arena` passed
//! in rather than re-deriving from `std.process.Init`) so other
//! callers (the nREPL session loop, the build-runner) can call
//! `runSource` with their own allocators without re-implementing
//! the bootstrap chain.

const std = @import("std");
const Writer = std.Io.Writer;

const Reader = @import("../eval/reader.zig").Reader;
const analyzeForm = @import("../eval/analyzer/analyzer.zig").analyze;
const macro_dispatch = @import("../eval/macro_dispatch.zig");
const driver = @import("../eval/driver.zig");
const evaluator = @import("../eval/evaluator.zig");
const Runtime = @import("../runtime/runtime.zig").Runtime;
const Env = @import("../runtime/env.zig").Env;
const Value = @import("../runtime/value/value.zig").Value;
const bootstrap = @import("../lang/bootstrap.zig");
const require_resolver = @import("../lang/require_resolver.zig");
const gc_torture = @import("../runtime/gc/gc_torture.zig");
const error_print = @import("../runtime/error/print.zig");
const print = @import("../runtime/print.zig");

const error_render = @import("error_render.zig");

/// Run `source_text` to completion, printing each form's value to
/// `stdout` and renderng any error to `stderr` before exiting via
/// `error_render.renderAndExit*` (= the process terminates on the
/// first error). Sets up its own Runtime / Env / macro_table /
/// bootstrap-loaded clojure.core surface; teardown lives on the
/// caller's defer chain (`rt.deinit()` etc.) — see `app/cli.zig`.
pub fn runSource(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    source_text: []const u8,
    source_label: []const u8,
    load_paths: []const []const u8,
) !void {
    const ctx = error_print.SourceContext{ .file = source_label, .text = source_text };

    // --- Runtime + Env + backend setup ---
    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    // Route println/print/prn through the SAME writer as the result-print
    // below — one offset-tracking stdout writer per process (D-096).
    rt.stdout = stdout;

    var env = try Env.init(&rt);
    defer env.deinit();

    driver.installVTable(&rt);

    // Bootstrap macros: intern `let` / `when` / `cond` /
    // `->` / `->>` / `and` / `or` / `if-let` / `when-let` as macro
    // Vars and populate the analyzer's MacroTable. Lives long enough
    // for the entire eval loop; no per-form re-construction.
    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();

    // Stage-1 prologue: install resolver + primitives + macros, then
    // restore the embedded `clojure.core` (the AOT path below; the
    // shared chain is F-009 `bootstrap.setupCore*`).
    // Errors here use the synthetic `<bootstrap>` source label and are
    // routed through the same catch path as user input — a broken
    // prologue surfaces as a diagnostic, not a panic.
    // ADR-0035 D7 / D-058 closure: bootstrap-time errors render via
    // `rt.source_registry`, which `bootstrap.loadCore` populates per
    // file. `bootstrap_ctx` remains the fallback for the first-file
    // case where the registry has not yet been populated.
    const bootstrap_ctx = error_print.SourceContext{ .file = bootstrap.SOURCE_LABEL, .text = bootstrap.CORE_SOURCE };
    // ADR-0056 Cycle 2b: restore clojure.core from the embedded AOT bytecode
    // envelope instead of parsing+analyzing+evaluating core.clj. The edge
    // cold-start win; the source path stays in `setupCore` for the build
    // tool. All `cljw -e` / file / stdin runs flow through here.
    bootstrap.setupCoreAot(arena, &rt, &env, &macro_table, @import("bootstrap_cache").data) catch |err| {
        error_render.renderAndExitRegistry(stderr, &rt, bootstrap_ctx, err);
    };

    // ADR-0084: enable filesystem `require` for user libs. setupCore* installs
    // the embedded-only resolver; swap to the embedded-FIRST chain + the
    // classpath so `(require '[my.lib])` loads `my/lib.clj` off `load_paths`.
    rt.load_paths = load_paths;
    require_resolver.installChained(&rt);

    // D-250: activate GC torture (if CLJW_GC_TORTURE armed it) only now that
    // core bootstrap is complete, so torture validates steady-state user-eval
    // rooting. The bootstrap namespace-creation window is out of scope (D-251).
    gc_torture.arm();

    // --- Read - Analyse - Eval - Print loop ---
    var reader = Reader.init(arena, source_text);
    while (true) {
        const form_opt = reader.read() catch |err| {
            error_render.renderAndExit(stderr, ctx, err);
        };
        const form = form_opt orelse break;

        const node = analyzeForm(arena, &rt, &env, null, form, &macro_table) catch |err| {
            error_render.renderAndExit(stderr, ctx, err);
        };

        var locals: [driver.MAX_LOCALS]Value = [_]Value{.nil_val} ** driver.MAX_LOCALS;
        const result = driver.evalForm(&rt, &env, &locals, arena, node) catch |err| {
            error_render.renderAndExit(stderr, ctx, err);
        };

        // GC-ROOT: D1 — pin the result across printResult [ref: .dev/gc_rooting.md §D]
        // printResult realises a lazy result (forcing thunks re-enters the VM →
        // torture / future auto-collect poll); `result` lives only in this Zig
        // local, on no operand stack or EvalFrame, so without the pin a collect
        // mid-print sweeps the seq + its source → UAF (hang or garbage). D-251 C9.
        try rt.gc.pin(result);
        try print.printResult(&rt, &env, stdout, result);
        _ = rt.gc.unpin(result);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}

/// ADR-0005 — `--compare` mode. Runs `source_text` through
/// both backends via `evaluator.compare`, prints `OK <value>` on
/// parity (NaN-boxed bit-equal), or `MISMATCH` + both renderings
/// on divergence (exit 1). Heap-allocated Values compare by
/// pointer-equality which differs across separately-allocated heap
/// objects even when the Clojure-level value matches — the
/// `evaluator.compare` docstring documents this caveat. Adopting a
/// `Value.eql`-based parity check would widen the comparison; the
/// gate uses bit-equality today.
pub fn runSourceCompare(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
    source_text: []const u8,
    source_label: []const u8,
) !void {
    _ = source_label;

    var rt = Runtime.init(io, gpa);
    defer rt.deinit();
    rt.stdout = stdout;

    var env = try Env.init(&rt);
    defer env.deinit();

    var macro_table = macro_dispatch.Table.init(gpa);
    defer macro_table.deinit();

    // `evaluator.compare` swaps the vtable internally — but bootstrap
    // needs ONE vtable installed first so `bootstrap.loadCore`'s
    // expand+eval path works. Use tree_walk for bootstrap (matches
    // production default); compare then re-installs per-run. Shared
    // one-chain bootstrap (F-009, `bootstrap.setupCore`).
    driver.installVTable(&rt);
    bootstrap.setupCore(arena, &rt, &env, &macro_table) catch |err| {
        try stderr.print("compare: bootstrap failed: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    const result = evaluator.compare(&rt, &env, &macro_table, arena, source_text);
    if (result.equal) {
        const value = result.tree_walk catch unreachable;
        try stdout.writeAll("OK ");
        try print.printValue(stdout, value);
        try stdout.writeByte('\n');
        try stdout.flush();
        return;
    }

    try stdout.writeAll("MISMATCH\n  tree_walk: ");
    if (result.tree_walk) |v| {
        try print.printValue(stdout, v);
    } else |err| {
        try stdout.print("ERROR {s}", .{@errorName(err)});
    }
    try stdout.writeAll("\n  vm:        ");
    if (result.vm) |v| {
        try print.printValue(stdout, v);
    } else |err| {
        try stdout.print("ERROR {s}", .{@errorName(err)});
    }
    try stdout.writeByte('\n');
    try stdout.flush();
    std.process.exit(1);
}
