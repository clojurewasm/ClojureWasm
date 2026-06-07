const std = @import("std");

pub fn main() !void {
    const n = 10000;
    var sum: i64 = 0;
    for (0..n) |i| {
        const v: i64 = @as(i64, @intCast(i)) * 3;
        if (@mod(v, 2) == 0) sum += v;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
