const std = @import("std");

const Record = struct {
    id: i64,
    value: i64,
    active: bool,
};

pub fn main() !void {
    const n = 10000;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const records = try alloc.alloc(Record, n);
    defer alloc.free(records);

    for (0..n) |i| {
        const ii: i64 = @intCast(i);
        records[i] = .{ .id = ii, .value = ii * 2, .active = (i % 3 == 0) };
    }

    var sum: i64 = 0;
    for (records) |r| {
        if (r.active) sum += r.value;
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
