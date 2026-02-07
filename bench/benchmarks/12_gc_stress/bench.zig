const std = @import("std");

const Triple = struct { a: i64, b: i64, c: i64 };

pub fn main() !void {
    const n = 100000;
    var sum: i64 = 0;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    for (0..n) |i| {
        const m = try alloc.create(Triple);
        m.* = .{ .a = @intCast(i), .b = @as(i64, @intCast(i)) + 1, .c = @as(i64, @intCast(i)) + 2 };
        sum += m.b;
        alloc.destroy(m);
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
