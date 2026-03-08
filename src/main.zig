const std = @import("std");

pub fn main() !void {
    const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
    _ = try stdout.write("ClojureWasm\n");
}

test "main prints ClojureWasm" {
    // Smoke test: module compiles
}
