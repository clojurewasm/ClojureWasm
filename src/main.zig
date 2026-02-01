const std = @import("std");

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("ClojureWasm v0.0.1\n", .{});
    try stdout.flush();
}
