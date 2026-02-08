// Build-time bootstrap cache generator.
//
// Runs during `zig build` to pre-compile bootstrap .clj sources into a
// serialized env snapshot. The main cljw binary embeds this cache and
// restores from it at startup, skipping parse/analyze/compile entirely.
//
// Usage (via build.zig, not intended for direct invocation):
//   cache_gen <output_file>

const std = @import("std");
const Env = @import("common/env.zig").Env;
const registry = @import("common/builtin/registry.zig");
const bootstrap = @import("common/bootstrap.zig");
const gc_mod = @import("common/gc.zig");
const keyword_intern = @import("common/keyword_intern.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var gc = gc_mod.MarkSweepGc.init(allocator);
    defer gc.deinit();
    const alloc = gc.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: cache_gen <output_file>\n", .{});
        std.process.exit(1);
    }

    // Initialize subsystems
    keyword_intern.init(allocator);
    defer keyword_intern.deinit();

    // Bootstrap from source
    var env = Env.init(allocator);
    defer env.deinit();
    try registry.registerBuiltins(&env);
    try bootstrap.loadBootstrapAll(alloc, &env);

    // Generate serialized cache (vmRecompileAll + serializeEnvSnapshot)
    const cache_bytes = try bootstrap.generateBootstrapCache(alloc, &env);

    // Write to output file
    const out_file = try std.fs.cwd().createFile(args[1], .{});
    defer out_file.close();
    try out_file.writeAll(cache_bytes);
}
