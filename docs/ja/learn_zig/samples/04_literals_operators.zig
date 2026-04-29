//! 04: 数値リテラルと演算子
//!
//! Zig の数値リテラル（10 進・16 進・桁区切り `_`）と、本リポジトリの
//! NaN ボックスタグ操作で頻出する算術・ビット・比較演算子を一通り
//! 触る。`runtime/value.zig` の packing / unpacking が同じ演算子で
//! 書かれていることを意識しておくと、その章を読むときに楽になる。
//!
//! 注: `@truncate` のような型変換系組込関数は第 6 章で本格的に紹介する。
//! ここではビットシフト結果を u16 に絞るために前借りで使う。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/04_literals_operators.zig`

const std = @import("std");

pub fn main() !void {
    // 16 進リテラル + 桁区切り `_`。本リポジトリの NaN ボックスのタグ
    // 定数（NB_INT_TAG など）はすべてこの形で書かれている
    const tag: u64 = 0xFFFC_0000_0000_0000;
    const payload: u64 = 1_234_567;

    // ビット演算子: AND `&` / OR `|` / XOR `^` / NOT `~`
    //              シフト `<<` / `>>`
    // タグと payload を OR で合成し、その結果から上位 16 ビットを取り出す
    const packed_value: u64 = tag | payload;
    const top16: u16 = @truncate(packed_value >> 48);
    // 下位 48 ビットだけを残すマスク
    const masked: u64 = packed_value & 0x0000_FFFF_FFFF_FFFF;

    // 算術演算: 整数除算 `/` は切り捨て、`%` は剰余
    const sum: i32 = 2 + 3 * 4;
    const div: i32 = 17 / 5;
    const rem: i32 = 17 % 5;

    // 比較演算子の結果は bool
    const eq: bool = sum == 14;
    const ne: bool = div != rem;

    // フォーマット指定子 `{X:0>16}` は「16 進大文字・幅 16・0 パディング」
    std.debug.print("[04] tag | payload      : 0x{X:0>16}\n", .{packed_value});
    std.debug.print("[04] top16 (>> 48)      : 0x{X}\n", .{top16});
    std.debug.print("[04] payload (& mask)   : {d}\n", .{masked});
    std.debug.print("[04] 2+3*4 / 17/5 / 17%5: {d} {d} {d}\n", .{ sum, div, rem });
    std.debug.print("[04] eq={} ne={}\n", .{ eq, ne });
}
