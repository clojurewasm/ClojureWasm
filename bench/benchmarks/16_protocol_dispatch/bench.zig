const std = @import("std");

const Computable = struct {
    factor: i64,

    fn compute(self: Computable, x: i64) i64 {
        return self.factor * x;
    }
};

pub fn main() !void {
    const n = 10000;
    const m = Computable{ .factor = 3 };
    var sum: i64 = 0;
    for (0..n) |i| {
        sum += m.compute(@intCast(i));
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
