const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- Build options (37.1: profiling infrastructure) ---
    const profile_opcodes = b.option(bool, "profile-opcodes", "Enable opcode frequency profiling") orelse false;
    const profile_alloc = b.option(bool, "profile-alloc", "Enable allocation size profiling") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "profile_opcodes", profile_opcodes);
    options.addOption(bool, "profile_alloc", profile_alloc);
    const options_module = options.createModule();

    // zwasm dependency (Wasm runtime library)
    const zwasm_dep = b.dependency("zwasm", .{
        .target = target,
        .optimize = optimize,
    });
    const zwasm_mod = zwasm_dep.module("zwasm");

    // Library module (test root)
    const mod = b.addModule("ClojureWasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("build_options", options_module);
    mod.addImport("zwasm", zwasm_mod);

    // --- Bootstrap cache generation (D81) ---
    // Build-time tool that bootstraps from .clj sources, serializes the env
    // snapshot, and writes it to a file. The main binary embeds this cache
    // for instant startup (restoreFromBootstrapCache instead of loadBootstrapAll).
    const cache_gen = b.addExecutable(.{
        .name = "cache_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cache_gen.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .ReleaseSafe,
        }),
    });
    cache_gen.root_module.addImport("build_options", options_module);
    cache_gen.root_module.addImport("zwasm", zwasm_mod);
    cache_gen.stack_size = 512 * 1024 * 1024;

    const run_cache_gen = b.addRunArtifact(cache_gen);
    const cache_bin = run_cache_gen.addOutputFileArg("bootstrap.cache");

    // Create a wrapper .zig file that @embedFile's the generated cache.
    // Both files live in the same WriteFile directory so the relative path works.
    const embed_files = b.addWriteFiles();
    _ = embed_files.addCopyFile(cache_bin, "bootstrap.cache");
    const wrapper = embed_files.add("bootstrap_cache.zig",
        \\pub const data: []const u8 = @embedFile("bootstrap.cache");
        \\
    );

    // Executable (same source tree, no module boundary — avoids self-referential type loop)
    const exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("build_options", options_module);
    exe.root_module.addImport("zwasm", zwasm_mod);
    exe.root_module.addAnonymousImport("bootstrap_cache", .{
        .root_source_file = wrapper,
    });
    // 512MB stack for Debug builds — deeply nested lazy-seq realization
    // (e.g. sieve of Eratosthenes with 168 nested filters) creates ~381KB
    // frames per recursion level in Debug mode. ReleaseSafe needs ~64MB.
    exe.stack_size = 512 * 1024 * 1024;
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the interpreter");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Wasm build step (wasm32-wasi)
    const wasm_exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .wasi,
            }),
            .optimize = optimize,
        }),
    });
    wasm_exe.root_module.addImport("build_options", options_module);
    const wasm_step = b.step("wasm", "Build for wasm32-wasi");
    const wasm_install = b.addInstallArtifact(wasm_exe, .{});
    wasm_step.dependOn(&wasm_install.step);

    // Test step
    const test_step = b.step("test", "Run all tests");

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    test_step.dependOn(&run_exe_tests.step);
}
