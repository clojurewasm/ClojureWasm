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
    build_options.addOption(bool, "phase_at_least_5", false);
    build_options.addOption(bool, "phase_at_least_7", false);
    build_options.addOption(bool, "phase_at_least_11", false);
    build_options.addOption(bool, "phase_at_least_14", false);
    build_options.addOption(bool, "phase_at_least_15", false);
    build_options.addOption(bool, "phase_at_least_17", false);
    exe_mod.addOptions("build_options", build_options);

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
