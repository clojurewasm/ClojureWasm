const std = @import("std");

const Record = struct {
    name: []const u8,
    age: i64,
    city: []const u8,
    score: i64,
    level: i64,
};

pub fn main() !void {
    const n = 100000;
    const m = Record{ .name = "Alice", .age = 30, .city = "NYC", .score = 95, .level = 5 };
    var sum: i64 = 0;
    for (0..n) |_| {
        sum += m.score;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
