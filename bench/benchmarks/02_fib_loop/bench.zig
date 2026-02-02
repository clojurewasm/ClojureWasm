const std = @import("std");

fn fib(n: i64) i64 {
    var a: i64 = 0;
    var b: i64 = 1;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        const t = a + b;
        a = b;
        b = t;
    }
    return a;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{fib(25)});
}
