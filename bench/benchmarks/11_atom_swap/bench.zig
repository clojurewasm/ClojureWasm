const std = @import("std");

pub fn main() !void {
    const n: i64 = 10000;
    var counter: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        counter += 1;
    }
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{counter});
}
