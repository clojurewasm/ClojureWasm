const std = @import("std");

pub fn main() !void {
    const limit = 1000;
    var sieve = [_]bool{true} ** (limit + 1);
    sieve[0] = false;
    sieve[1] = false;

    var i: usize = 2;
    while (i * i <= limit) : (i += 1) {
        if (sieve[i]) {
            var j = i * i;
            while (j <= limit) : (j += i) sieve[j] = false;
        }
    }

    var count: i64 = 0;
    for (2..limit + 1) |k| {
        if (sieve[k]) count += 1;
    }
    const stdout = std.io.getStdOut().writer();
    try stdout.print("{d}\n", .{count});
}
