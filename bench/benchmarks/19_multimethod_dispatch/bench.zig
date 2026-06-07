const std = @import("std");

const OpType = enum { add, mul, sub };

const Op = struct {
    op_type: OpType,
    a: i64,
    b: i64,
};

fn process(op: Op) i64 {
    return switch (op.op_type) {
        .add => op.a + op.b,
        .mul => op.a * op.b,
        .sub => op.a - op.b,
    };
}

pub fn main() !void {
    const n = 10000;
    const data = Op{ .op_type = .add, .a = 3, .b = 4 };
    var sum: i64 = 0;
    for (0..n) |_| {
        sum += process(data);
    }
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    const stdout = &writer.interface;
    try stdout.print("{d}\n", .{sum});
    try stdout.flush();
}
