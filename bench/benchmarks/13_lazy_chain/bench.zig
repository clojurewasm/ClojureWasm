const std = @import("std");

pub fn main() !void {
    var sum: i64 = 0;
    var count: usize = 0;
    var i: i64 = 0;
    while (count < 10000) : (i += 1) {
        const v = i * 3;
        if (@mod(v, 2) == 0) {
            sum += v;
            count += 1;
        }
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
