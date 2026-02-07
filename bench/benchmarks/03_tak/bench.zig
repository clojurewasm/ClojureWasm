const std = @import("std");

fn tak(x: i64, y: i64, z: i64) i64 {
    if (x <= y) return z;
    return tak(tak(x - 1, y, z), tak(y - 1, z, x), tak(z - 1, x, y));
}

pub fn main() !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{tak(18, 12, 6)});
    try stdout.flush();
}
