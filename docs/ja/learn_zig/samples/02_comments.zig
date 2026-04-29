//! 02: コメント — `//` `///` `//!`
//!
//! このファイル先頭の `//!` 行はモジュールレベルの doc comment。
//! `///` は直後の宣言（型・関数・フィールド）に紐づく doc comment。
//! `//` は doc ではない普通のインラインコメント。
//!
//! 本リポジトリでは「すべての .zig 先頭に `//!`」「すべての `pub`
//! 宣言に `///`」を付ける方針（`.claude/rules/zig_tips.md`）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/02_comments.zig`

const std = @import("std");

/// `square(x)` は x の二乗を返す（宣言 doc comment はこの位置に書く）。
fn square(x: i32) i32 {
    // 普通のコメントは関数本体の中に書く。i32 の乗算は debug ビルドで
    // オーバーフロー時に panic するので、入力範囲には注意する
    return x * x;
}

pub fn main() !void {
    std.debug.print("[02] square(7) = {d}\n", .{square(7)});
    std.debug.print("[02] '///' = 宣言 doc, '//!' = モジュール doc, '//' = 普通のコメント\n", .{});
}
