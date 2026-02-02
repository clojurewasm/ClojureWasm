const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (test root)
    const mod = b.addModule("ClojureWasm", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Executable (same source tree, no module boundary — avoids self-referential type loop)
    const exe = b.addExecutable(.{
        .name = "cljw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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
