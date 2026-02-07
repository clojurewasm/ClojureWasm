const std = @import("std");

pub fn main() !void {
    const n = 10000;
    var c: i64 = 0;
    for (0..n) |_| {
        c += 1;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{c});
    try stdout.flush();
}
