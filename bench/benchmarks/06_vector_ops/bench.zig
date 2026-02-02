const std = @import("std");

pub fn main() !void {
    const n = 10000;
    var vec: [n]i64 = undefined;
    for (0..n) |i| vec[i] = @intCast(i);

    var sum: i64 = 0;
    for (0..n) |i| sum += vec[i];

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{sum});
}
