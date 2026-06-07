const std = @import("std");

pub fn main() !void {
    const n = 10000;
    var arr: [n]i64 = undefined;
    for (0..n) |i| arr[i] = @intCast(i);

    for (0..n) |i| arr[i] = arr[i] * arr[i];

    var sum: i64 = 0;
    for (0..n) |i| {
        if (@mod(arr[i], 2) == 0) sum += arr[i];
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
