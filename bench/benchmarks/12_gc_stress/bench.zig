const std = @import("std");

/// Hash map allocation to match Clojure's {:a i :b (+ i 1) :c (+ i 2)}
pub fn main() !void {
    const n = 100000;
    var sum: i64 = 0;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    for (0..n) |i| {
        var map = std.StringHashMap(i64).init(alloc);
        try map.put("a", @intCast(i));
        try map.put("b", @as(i64, @intCast(i)) + 1);
        try map.put("c", @as(i64, @intCast(i)) + 2);
        sum += map.get("b").?;
        map.deinit();
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
