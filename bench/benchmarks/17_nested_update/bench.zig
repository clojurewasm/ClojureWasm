const std = @import("std");

/// Nested hash map update to match Clojure's (update-in m [:a :b :c] inc)
pub fn main() !void {
    const n = 10000;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // Build nested maps: {:a {:b {:c 0}}}
    var level_c = std.StringHashMap(i64).init(alloc);
    defer level_c.deinit();
    try level_c.put("c", 0);

    // Navigate and update via hash lookup each iteration
    for (0..n) |_| {
        const old = level_c.get("c").?;
        try level_c.put("c", old + 1);
    }

    const result = level_c.get("c").?;
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{result});
    try stdout.flush();
}
