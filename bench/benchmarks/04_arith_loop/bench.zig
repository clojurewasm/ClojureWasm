const std = @import("std");

pub fn main() !void {
    const n: i64 = 1000000;
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        sum += i;
    }
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{sum});
}
