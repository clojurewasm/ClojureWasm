const std = @import("std");
// TODO(adr-0003): drop zlinter dep when Zig ships @deprecated()
// builtin + -fdeprecated flag (ziglang/zig#22822, accepted on
// urgent milestone, expected 0.17+).
const zlinter = @import("zlinter");

// Lint lives in its own build root so this development-only import is never
// configured by normal/release builds. build.zig delegates its public `lint`
// step here and forwards all arguments after `--`.
pub fn build(b: *std.Build) void {
    const lint_step = b.step("lint", "Lint source code (zlinter).");
    lint_step.dependOn(blk: {
        var builder = zlinter.builder(b, .{});
        // Lint THIS checkout's sources only. With no paths set zlinter walks
        // every `.zig` under the cwd, which sweeps in any nested git worktree
        // (`.claude/worktrees/<branch>`, `.dev/wt-golden`) and reports another
        // branch's warnings as this one's.
        builder.addPaths(.{ .include = &.{ b.path("src"), b.path("build.zig"), b.path("build-lint.zig") } });
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
