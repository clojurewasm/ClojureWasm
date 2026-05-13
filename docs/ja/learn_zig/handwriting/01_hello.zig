//! 01: Hello, world

const std = @import("std");

pub fn main() !void {
    std.debug.print("[01] Hello from Zig 0.16!\n", .{});
    std.debug.print("[01] formatted: {s} = {d}\n", .{ "answer", 42 });
}
