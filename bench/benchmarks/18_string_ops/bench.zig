const std = @import("std");

pub fn main() !void {
    const n = 100000;
    var sum: i64 = 0;
    var fmtbuf: [32]u8 = undefined;
    for (0..n) |i| {
        const slice = std.fmt.bufPrint(&fmtbuf, "{d}", .{i}) catch unreachable;
        sum += @intCast(slice.len);
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
