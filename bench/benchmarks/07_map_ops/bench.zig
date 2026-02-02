const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var map = std.AutoHashMap(i64, i64).init(alloc);
    defer map.deinit();

    const n: i64 = 1000;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        try map.put(i, i);
    }

    var sum: i64 = 0;
    i = 0;
    while (i < n) : (i += 1) {
        sum += map.get(i).?;
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{sum});
}
