const std = @import("std");

/// Filter-based sieve: match Clojure's functional approach
pub fn main() !void {
    const limit = 1000;
    var cand: [limit - 1]i32 = undefined;
    var len: usize = 0;
    for (2..limit + 1) |i| {
        cand[len] = @intCast(i);
        len += 1;
    }

    var count: i64 = 0;
    while (len > 0) {
        const p = cand[0];
        count += 1;
        var new_len: usize = 0;
        for (1..len) |i| {
            if (@mod(cand[i], p) != 0) {
                cand[new_len] = cand[i];
                new_len += 1;
            }
        }
        len = new_len;
    }

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{count});
    try stdout.flush();
}
