const std = @import("std");
// TODO(adr-0003): drop zlinter dep when Zig ships @deprecated()
// builtin + -fdeprecated flag (ziglang/zig#22822, accepted on
// urgent milestone, expected 0.17+).
const zlinter = @import("zlinter");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Phase activation manifest (ADR-0023 Pattern A). One comptime
    // bool per future phase boundary; each flips from false to true
    // at the phase's opening commit. Source uses
    // `if (build_options.phase_at_least_N) ... else stub` to choose
    // between the real and stub modules without a runtime branch.
    const build_options = b.addOptions();
    build_options.addOption(bool, "phase_at_least_5", true);
    build_options.addOption(bool, "phase_at_least_6", true);
    build_options.addOption(bool, "phase_at_least_7", true);
    build_options.addOption(bool, "phase_at_least_11", true);
    build_options.addOption(bool, "phase_at_least_14", false);
    build_options.addOption(bool, "phase_at_least_15", false);
    build_options.addOption(bool, "phase_at_least_17", false);

    // `--version` / `--help` banner string, auto-derived from the single
    // source of truth (`build.zig.zon .version`) so the CLI never hand-maintains
    // a version literal. The user owns the value via the release tag.
    const build_zon = @import("build.zig.zon");
    build_options.addOption([]const u8, "version", build_zon.version);

    // ROADMAP §9.6 / 4.8 / §349 — backend gate (ADR-0005 / ADR-0070 / F-012).
    // `vm` is the PRODUCTION DEFAULT (flipped 2026-06-02 once every D-196
    // parity blocker closed: check_vm_parity = 0 fails, corpus 375/375 + all
    // e2e green on vm). `tree-walk` is retained as the differential oracle /
    // reference implementation, selectable via `-Dbackend=tree-walk`.
    const Backend = enum { tree_walk, vm };
    const backend = b.option(Backend, "backend", "Evaluation backend (vm default — production; tree-walk = differential oracle)") orelse .vm;
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
        \\pub const data: []const u8 = @embedFile("bootstrap_core.cljc");
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

    // `zig build zwasm-spike` — D-037 / F-001 zwasm v2 embedding spike.
    // Behind `-Dzwasm-spike` + a LAZY path-dep (build.zig.zon) so the default
    // build + `bash test/run_all.sh` gate never resolve zwasm (which is under
    // active dev on its `zwasm-from-scratch` branch — a churning tree must not
    // break cljw's gate). Proves cljw can consume zwasm's Zig embedding API via
    // a relative-path import. `b.lazyDependency` returns null on the first pass
    // if a fetch is needed (Zig re-runs build); skip the step until it resolves.
    const zwasm_spike = b.option(bool, "zwasm-spike", "Build + run the zwasm v2 embedding spike (D-037).") orelse false;
    if (zwasm_spike) {
        if (b.lazyDependency("zwasm", .{ .target = target, .optimize = optimize })) |zw| {
            const spike_mod = b.createModule(.{
                .root_source_file = b.path("spike/zwasm_embed.zig"),
                .target = target,
                .optimize = optimize,
            });
            spike_mod.addImport("zwasm", zw.module("zwasm"));
            const spike_exe = b.addExecutable(.{ .name = "zwasm-spike", .root_module = spike_mod });
            const run_spike = b.addRunArtifact(spike_exe);
            const spike_step = b.step("zwasm-spike", "Build + run the zwasm v2 embedding spike (D-037).");
            spike_step.dependOn(&run_spike.step);
        }
    }

    // `zig build lint` — zlinter rule chain (ADR-0003).
    // Mac-host gate (zlinter requires `zig fetch` against GitHub;
    // OrbStack runs without network reach by design). Run with
    // `--max-warnings 0` for strict CI semantics.
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
