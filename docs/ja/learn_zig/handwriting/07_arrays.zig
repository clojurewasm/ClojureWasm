//! 07: 配列

const std = @import("std");

pub fn main() !void {
    const fib: [6]u32 = .{ 1, 1, 2, 3, 5, 8 }; // [6]u32 の [6]も固定長配列の型の一部([8]u32とは違う)
    std.debug.print("[07] fib : {any}\n", .{fib}); // 配列一括printは{any}
    std.debug.print("[07] fib[5] : {d}\n", .{fib[5]});

    const primes = [_]u32{ 2, 3, 5, 7, 11 }; // コンパイル時型推論
    std.debug.print("[07] primes.len : {d}\n", .{primes.len}); // .lenで長さにアクセス

    const zeros: [4]u32 = [_]u32{0} ** 4; // 初期化の反復は ** X
    std.debug.print("[07] zeros : {any}\n", .{zeros});

    const grid: [2][3]u8 = .{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
    };
    std.debug.print("[07] grid : {any}\n", .{grid}); // 多次元配列もprintできる
    std.debug.print("[07] grid[1][2] : {d}\n", .{grid[1][2]});

    // インデックスはusizeである
    var i: usize = 0;
    var sum: u32 = 0;
    while (i < primes.len) : (i += 1) {
        sum += primes[i];
        std.debug.print("[07] sum : {d}\n", .{sum});
    }
    std.debug.print("[07] sum of primes : {d}\n", .{sum});
}
