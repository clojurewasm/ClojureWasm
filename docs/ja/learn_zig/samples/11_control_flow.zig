//! 11: 制御構文 — `if` / `while` / `for` / `switch`
//!
//! Zig では `if` も `switch` も「式」。値を返す代入の右辺に書ける。
//! `while` は末尾の継続式 `(i += 1)` を分離して書く Zig 独特の形を
//! 持つ。`for` はスライスとレンジ `0..n` の両方を走れる。
//! `switch` はデフォルト網羅必須で、整数レンジ・enum・タグ付き
//! union（→ 第 15 章）に使える。
//!
//! 注: `switch` の例で enum を先取りで使う（enum 自体は第 14 章で詳説）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/11_control_flow.zig`

const std = @import("std");

const Op = enum { add, sub, mul };

// 整数レンジでの switch — `1...9` は 1 から 9 までを含む
fn classify(n: i32) []const u8 {
    return switch (n) {
        0 => "zero",
        1...9 => "single digit",
        10...99 => "two digits",
        else => "large",
    };
}

pub fn main() !void {
    // `if` は式。三項演算子 `cond ? a : b` の代わりにそのまま書ける
    const x: i32 = 7;
    const sign: []const u8 = if (x > 0) "positive" else if (x < 0) "negative" else "zero";
    std.debug.print("[11] sign of {d}        : {s}\n", .{ x, sign });

    // `while (cond) : (continue-expr) { ... }` — 末尾の更新式が分離している
    var i: u32 = 0;
    var sum: u32 = 0;
    while (i < 5) : (i += 1) sum += i;
    std.debug.print("[11] sum 0..5           : {d}\n", .{sum});

    // スライス上の `for` — 各要素を `|w|` で捕捉
    const words = [_][]const u8{ "alpha", "beta", "gamma" };
    for (words) |w| std.debug.print("[11] word              : {s}\n", .{w});

    // インデックス付き for — 第 2 の引数 `0..` を渡す
    for (words, 0..) |w, idx| {
        std.debug.print("[11]   #{d} = {s}\n", .{ idx, w });
    }

    // レンジ for — `1..6` は 1 から 5 まで（end 排他）
    // 捕捉した `n` は usize なので `@intCast` で u32 に縮める
    var product: u32 = 1;
    for (1..6) |n| product *= @intCast(n);
    std.debug.print("[11] 5! via for-range   : {d}\n", .{product});

    // 整数レンジの switch — `else =>` でフォールスルー
    std.debug.print("[11] classify(5)        : {s}\n", .{classify(5)});
    std.debug.print("[11] classify(42)       : {s}\n", .{classify(42)});
    std.debug.print("[11] classify(9999)     : {s}\n", .{classify(9999)});

    // enum 上の switch — 全タグの網羅が義務付けられているので、`else` 不要
    const op: Op = .mul;
    const label = switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
    };
    std.debug.print("[11] op label           : {s}\n", .{label});
}
