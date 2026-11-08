const std = @import("std");

pub fn build(b: *std.Build) void {
    // wasm32 needs the atomics + bulk_memory features (rationale: kanban
    // CLJW-WASM32-PORT / hive memory). Added automatically so the target is
    // just `-Dtarget=wasm32-wasi`, no hand-passed `-Dcpu`.
    const target = blk: {
        const t = b.standardTargetOptions(.{});
        if (t.result.cpu.arch != .wasm32) break :blk t;
        var q = t.query;
        q.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.atomics));
        q.cpu_features_add.addFeature(@intFromEnum(std.Target.wasm.Feature.bulk_memory));
        break :blk b.resolveTargetQuery(q);
    };
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
    build_options.addOption(bool, "embed_raw_clj_sources", false);

    // Layer 7 (ADR-0186) — the property suite's seed and iteration count. Both
    // are FIXED by default: a gate whose input set changes per run reports a
    // different thing each time it is asked, and a failure nobody can reproduce
    // is a failure nobody fixes. A sweep raises them deliberately:
    //   zig build test -Dprop-seed=0xdecafbad -Dprop-iters=5000
    // A property that only fails under a swept seed is still a real defect —
    // pin its seed into the default when that happens, so the gate keeps it.
    build_options.addOption(u64, "prop_seed", b.option(u64, "prop-seed", "Layer 7 property-test seed (ADR-0186)") orelse 0x1_0BE1_5EED);
    build_options.addOption(usize, "prop_iters", b.option(usize, "prop-iters", "Layer 7 property-test iterations per property (ADR-0186)") orelse 60);

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

    // `-Dffi`: the `cljw.ffi` C FFI surface (ADR-0202): dlopen + a
    // register-only call shape, so it exists only where that shape is the C
    // ABI (x86_64 SysV, aarch64 AAPCS64) on a dlopen host (Linux, macOS).
    // On by default there; `-Dffi=false` drops it. Off on wasm and Windows.
    const ffi_requested = b.option(bool, "ffi", "Build the cljw.ffi C FFI surface where the target supports it (ADR-0202).") orelse true;
    const ffi_target = switch (target.result.cpu.arch) {
        .x86_64, .aarch64 => target.result.os.tag == .linux or target.result.os.tag.isDarwin(),
        else => false,
    };
    const ffi_enabled = ffi_requested and ffi_target;
    build_options.addOption(bool, "ffi", ffi_enabled);
    // dlopen/dlsym/dlerror come from libc: link it explicitly whenever ffi is on.
    if (ffi_enabled) exe_mod.link_libc = true;

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
    // C5'-b (ADR-0173): cache_gen embeds the RAW .clj sources (host tool —
    // its size is irrelevant) and is the producer of the compressed sources
    // blob; the shipped cljw embeds only the blob. The flag picks the mode.
    const cache_gen_options = b.addOptions();
    cache_gen_options.addOption([]const u8, "version", build_zon.version);
    cache_gen_options.addOption(Backend, "backend", backend);
    cache_gen_options.addOption(bool, "wasm", wasm_enabled);
    cache_gen_options.addOption(bool, "ffi", ffi_enabled);
    cache_gen_options.addOption(bool, "embed_raw_clj_sources", true);
    cache_gen_mod.addOptions("build_options", cache_gen_options);
    if (ffi_enabled) cache_gen_mod.link_libc = true;
    if (zwasm_mod) |zm| cache_gen_mod.addImport("zwasm", zm);
    const cache_gen = b.addExecutable(.{ .name = "cache_gen", .root_module = cache_gen_mod });
    const run_cache_gen = b.addRunArtifact(cache_gen);
    const bootstrap_cache_blob = run_cache_gen.addOutputFileArg("bootstrap_core.cljc");
    const bootstrap_sources_blob = run_cache_gen.addOutputFileArg("bootstrap_sources.bin");
    const cache_wf = b.addWriteFiles();
    _ = cache_wf.addCopyFile(bootstrap_cache_blob, "bootstrap_core.cljc");
    _ = cache_wf.addCopyFile(bootstrap_sources_blob, "bootstrap_sources.bin");
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
    // C5'-b: the flate-compressed .clj sources blob (label -> compressed
    // text index; produced by cache_gen). The shipped cljw decompresses a
    // file's text on demand (error-context render / source-replay fallback)
    // instead of carrying 451KB of raw .clj in rodata.
    const sources_wrapper = cache_wf.add("bootstrap_sources.zig",
        \\// Generated by build.zig (ADR-0173 C5'-b). Do not edit.
        \\pub const data: []const u8 = @embedFile("bootstrap_sources.bin");
        \\
    );
    exe_mod.addAnonymousImport("bootstrap_sources", .{ .root_source_file = sources_wrapper });
    // cache_gen runs in raw mode and never reads the blob — a stub keeps the
    // @import("bootstrap_sources") in shared bootstrap code resolvable. The
    // stub MUST come from its own WriteFiles: cache_wf depends on cache_gen's
    // output, so wiring cache_gen's import through cache_wf is a dependency
    // loop (cache_gen -> cache_wf -> run cache_gen).
    const stub_wf = b.addWriteFiles();
    const sources_stub = stub_wf.add("bootstrap_sources_stub.zig",
        \\// Generated by build.zig (ADR-0173 C5'-b). cache_gen stub.
        \\pub const data: []const u8 = "";
        \\
    );
    cache_gen_mod.addAnonymousImport("bootstrap_sources", .{ .root_source_file = sources_stub });

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

    // `zig build lint` delegates to a separate build root. Keeping
    // @import("zlinter") out of this file is load-bearing: Zig resolves build
    // imports while configuring EVERY command, so an eager import made release
    // builds fetch zlinter plus its transitive zls tree (CLJW-RELEASE-FETCH).
    // The package is lazy in build.zig.zon and build-lint.zig is configured only
    // when this step executes, preserving the public CLI without exposing
    // normal/release builds to a development-only network dependency.
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    const lint_cmd = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        "build-lint.zig",
        "lint",
    });
    lint_cmd.setCwd(b.path("."));
    if (b.args) |args| {
        lint_cmd.addArg("--");
        lint_cmd.addArgs(args);
    }
    lint_step.dependOn(&lint_cmd.step);
}
