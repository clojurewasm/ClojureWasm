const std = @import("std");

const Node = struct {
    val: i64,
    next: ?*Node,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const n: i64 = 10000;
    var head: ?*Node = null;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const node = try alloc.create(Node);
        node.* = .{ .val = i, .next = head };
        head = node;
    }

    var count: i64 = 0;
    var cur = head;
    while (cur) |c| {
        count += 1;
        const next = c.next;
        alloc.destroy(c);
        cur = next;
    }

    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{count});
    try stdout.flush();
}
