const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;
    try stdout.writeAll("ClojureWasm\n");
    try stdout.flush();
}

test "smoke: main module loads" {
    try std.testing.expect(true);
}

// Pull in tests from the runtime tree. As more files appear under
// src/runtime/, add them here so the unified `zig build test` discovers them.
test {
    _ = @import("runtime/value.zig");
}
