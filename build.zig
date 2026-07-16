const std = @import("std");
// TODO(adr-0003): drop zlinter dep when Zig ships @deprecated()
// builtin + -fdeprecated flag (ziglang/zig#22822, accepted on
// urgent milestone, expected 0.17+).
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `-Dprofile` (D-450 perf campaign): keep the symbol table on an OPTIMISED
    // build so `sample` / Instruments / dtrace can attribute the hot path
    // per-function. Without it, a release build is stripped (below) → profilers
    // catch-all huge code ranges into one exported symbol, making the campaign's
    // per-target deep-dive method (now that v0 is mined) unreliable. Profiling
    // only; the SHIPPED artifact stays stripped. Default false.
    const profile = b.option(bool, "profile", "Keep symbols on an optimised build for profiling (perf campaign)") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // Strip the symbol table from release builds: it is ~400 KB (~10%) of
        // the binary, and binary size is ClojureWasm's headline metric
        // (bench/RELEASE_METRICS.md). cljw renders its own error traces from a
        // runtime StackFrame stack, NOT native symbols, so stripping costs no
        // user-facing diagnostics. Debug stays unstripped for dev tooling
        // (lldb / native backtraces). Aligns the installed artifact with the
        // already-documented stripped release size (O-008). (Debug-mode `zig
        // build test` is unaffected — strip is false there.) `-Dprofile` keeps
        // symbols on an optimised build for the perf-campaign profiler.
        .strip = optimize != .Debug and !profile,
        // Drop unwind tables from release builds: __eh_frame + __unwind_info
        // were 749 KB (~8%) of the shipped binary, and a STRIPPED build
        // already prints no native stack trace on a Zig-level panic (probed
        // 2026-07-16: "stack tracing is disabled" with and without the
        // tables), so they bought nothing user-visible. cljw renders Clojure
        // errors from its own StackFrame stack; arm64 keeps frame pointers,
        // so an attached debugger can still walk frames. Debug + `-Dprofile`
        // keep the tables for dev tooling. ADR-0172 L1 / O-052.
        .unwind_tables = if (optimize != .Debug and !profile) .none else null,
    });

    // Build-time options module (consumed via `@import("build_options")`):
    // the `--version` banner (below) + the backend gate (below). The ADR-0023
    // `phase_at_least_N` phase-activation flags were RETIRED 2026-06-15
    // (ADR-0142 / D-440 R5): they guarded ZERO live code paths (the comptime-stub
    // staging shipped directly, never behind the flag) and were stale
    // (phase_at_least_15 = false while concurrency is BUILT). The §9 reframe
    // replaced the phase model with gap areas; no `phase_at_least_*` reference
    // remains in src/.
    const build_options = b.addOptions();

    // `--version` / `--help` banner string, auto-derived from the single
    // source of truth (`build.zig.zon .version`) so the CLI never hand-maintains
    // a version literal. The user owns the value via the release tag.
    const build_zon = @import("build.zig.zon");
    build_options.addOption([]const u8, "version", build_zon.version);

    // ROADMAP §9.6 / 4.8 / §349 — backend gate (ADR-0005 / ADR-0070 / F-012).
    // `vm` is the PRODUCTION DEFAULT (flipped 2026-06-02 once every D-196
    // parity blocker closed: check_vm_parity = 0 fails, corpus 375/375 + all
    // e2e green on vm). `tree_walk` is retained as the differential oracle /
    // reference implementation, selectable via `-Dbackend=tree_walk` (the
    // enum FIELD spelling — `-Dbackend=tree-walk` is rejected by zig build).
    const Backend = enum { tree_walk, vm };
    const backend = b.option(Backend, "backend", "Evaluation backend (vm default — production; tree_walk = differential oracle)") orelse .vm;
    build_options.addOption(Backend, "backend", backend);

    // `-Dwasm` — the minimal polyglot Wasm FFI surface (ADR-0099 / CFP P1).
    // F-001 isolation: link zwasm v2 INTO the cljw binary + activate the `wasm`
    // namespace, but ONLY when the flag is set AND the lazy `zwasm` dep actually
    // resolves. `build_options.wasm` is set true *only inside* the resolved-dep
    // block, so the null-first-pass of `b.lazyDependency` (fetch pending) leaves
    // it false — `runtime/cljw/wasm/*.zig` (and its `@import("zwasm")`) is then
    // not analysed, so no compile error. The default build / `run_all.sh` gate
    // never reach `b.lazyDependency` with the flag → no fetch, no zwasm symbols.
    const wasm = b.option(bool, "wasm", "Build with the polyglot Wasm FFI surface (embeds zwasm v2, ADR-0099).") orelse false;
    var wasm_enabled = false;
    var zwasm_mod: ?*std.Build.Module = null;
    if (wasm) {
        if (b.lazyDependency("zwasm", .{ .target = target, .optimize = optimize })) |zw| {
            zwasm_mod = zw.module("zwasm");
            wasm_enabled = true;
        }
    }
    build_options.addOption(bool, "wasm", wasm_enabled);
    // Both the cljw exe AND the build-time bootstrap tool (cache_gen, below)
    // root the runtime tree, so both analyse the `if (build_options.wasm)` wasm
    // branch in `runtime/cljw/_host_api.zig` and both need the `zwasm` import
    // when the flag is on (Phase-16-consistent: wasm becomes always-on there).
    if (zwasm_mod) |zm| exe_mod.addImport("zwasm", zm);

    exe_mod.addOptions("build_options", build_options);

    // ADR-0056 Cycle 2: AOT-compile the eager bootstrap (clojure.core) to a
    // bytecode envelope at build time + embed it. `cache_gen` (a host tool)
    // runs the VM compiler over core.clj so the fns carry bytecode, writes
    // the blob, and a generated wrapper `@embedFile`s it into the cljw exe.
    // (Step 2a: the blob is embedded + verified non-empty by a test, but
    // setupCore still uses loadCore on the production path; the restore swap
    // is Step 2b.) `bootstrap_cache.data` is the embedded envelope bytes.
    const cache_gen_mod = b.createModule(.{
        .root_source_file = b.path("src/cache_gen.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    cache_gen_mod.addOptions("build_options", build_options);
    if (zwasm_mod) |zm| cache_gen_mod.addImport("zwasm", zm);
    const cache_gen = b.addExecutable(.{ .name = "cache_gen", .root_module = cache_gen_mod });
    const run_cache_gen = b.addRunArtifact(cache_gen);
    const bootstrap_cache_blob = run_cache_gen.addOutputFileArg("bootstrap_core.cljc");
    const cache_wf = b.addWriteFiles();
    _ = cache_wf.addCopyFile(bootstrap_cache_blob, "bootstrap_core.cljc");
    const cache_wrapper = cache_wf.add("bootstrap_cache.zig",
        \\// Generated by build.zig (ADR-0056 Cycle 2). Do not edit.
        \\// ADR-0173 C3': comptime-copy into align(8) rodata so the v7
        \\// blob's 4B-aligned instr sections are readable in place
        \\// (@embedFile alone guarantees only align 1).
        \\const raw = @embedFile("bootstrap_core.cljc");
        \\const aligned: [raw.len]u8 align(8) = raw.*;
        \\pub const data: []const u8 = &aligned;
        \\
    );
    exe_mod.addAnonymousImport("bootstrap_cache", .{ .root_source_file = cache_wrapper });

    const exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the executable");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest(.{ .root_module = exe_mod });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // `zig build lint` — zlinter rule chain (ADR-0003).
    // Runs where zlinter can be fetched from GitHub; the gate skips it on
    // hosts without network reach. Run with `--max-warnings 0` for strict
    // CI semantics.
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    lint_step.dependOn(blk: {
        var builder = zlinter.builder(b, .{});
        // Phase A.
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        // Phase B (added one at a time — see ADR-0003 Update).
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .builtin = .no_empty_block }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        // Inspected, not adopted (rationale in ADR-0003 Update):
        //   require_exhaustive_enum_switch — mismatched with the
        //     Value.Tag dispatch idiom (36+ tags, intentionally
        //     growing through Phases 4-15; arithmetic / collection
        //     primitives use `else =>` to mean "all the kinds I do
        //     not accept as operand").
        break :blk builder.build();
    });
}
