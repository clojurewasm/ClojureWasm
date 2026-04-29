//! 01: Hello, world
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/01-hello.zig`
//!
//! この章で確認すること:
//!   - `@import("std")` で標準ライブラリを取り込む
//!   - `pub fn main() !void` — 最小のエントリポイント
//!   - `std.debug.print` — stderr に手早く出力するデバッグ用関数
//!   - `.{ ... }` 匿名タプル構文（フォーマット引数の渡し方）

const std = @import("std");

pub fn main() !void {
    // 第 2 引数が `.{}` の場合は引数なし（フォーマット指定子なしの素文字列）
    std.debug.print("[01] Hello from Zig 0.16!\n", .{});
    // `{s}` は文字列、`{d}` は整数。引数は `.{ ... }` で並べる
    std.debug.print("[01] formatted: {s} = {d}\n", .{ "answer", 42 });
}
