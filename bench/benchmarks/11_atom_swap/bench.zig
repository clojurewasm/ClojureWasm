const std = @import("std");

pub fn main() !void {
    const n: i64 = 10000;
    var counter: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        counter += 1;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{counter});
    try stdout.flush();
}
