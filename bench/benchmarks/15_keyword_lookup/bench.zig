const std = @import("std");

/// Hash map lookup to match Clojure's keyword map access
pub fn main() !void {
    const n = 100000;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    var map = std.StringHashMap(i64).init(alloc);
    defer map.deinit();

    try map.put("name", 0);
    try map.put("age", 30);
    try map.put("city", 0);
    try map.put("score", 95);
    try map.put("level", 5);

    var sum: i64 = 0;
    for (0..n) |_| {
        sum += map.get("score").?;
    }

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
