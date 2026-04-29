//! 07: 配列 — `[N]T` / `[_]T{ ... }` / 反復 `** N` / `.len`
//!
//! 固定長配列はスタック（または struct のフィールド）に置く。長さも
//! 型の一部なので `[6]u32` と `[8]u32` は別の型扱いになる。`[_]T{ ... }`
//! と書けば長さはコンパイラが推論する。
//!
//! `** N` は配列の繰り返し演算子。本リポジトリの
//! `[_]Value{.nil_val} ** MAX_LOCALS` のように、特定の値で埋めた
//! 固定長スロット表を作るのに使う。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/07_arrays.zig`

const std = @import("std");

pub fn main() !void {
    // `[N]T` — 長さを明示
    const fib: [6]u32 = .{ 1, 1, 2, 3, 5, 8 };

    // `[_]T{ ... }` — 長さは要素数から推論
    const primes = [_]u32{ 2, 3, 5, 7, 11 };

    // `** N` — 配列の反復。0 で 4 要素を埋める
    const zeros: [4]u32 = [_]u32{0} ** 4;

    // 多次元配列 `[N][M]T`
    const grid: [2][3]u8 = .{
        .{ 1, 2, 3 },
        .{ 4, 5, 6 },
    };

    // `.len` はコンパイル時に長さが分かるので usize を返す
    std.debug.print("[07] fib[5]             : {d}\n", .{fib[5]});
    std.debug.print("[07] primes.len         : {d}\n", .{primes.len});
    std.debug.print("[07] zeros              : {any}\n", .{zeros});
    std.debug.print("[07] grid[1][2]         : {d}\n", .{grid[1][2]});

    // インデックスは usize。実行時の値でアクセスする例
    var i: usize = 0;
    var sum: u32 = 0;
    while (i < primes.len) : (i += 1) sum += primes[i];
    std.debug.print("[07] sum of primes      : {d}\n", .{sum});
}
