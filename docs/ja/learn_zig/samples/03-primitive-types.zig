//! 03: 基本型 — 整数・浮動小数・bool・void
//!
//! 本リポジトリで実際に登場する基本型を一通り触る。
//!   - u8  生バイト・ASCII 文字・HeapTag の格納整数
//!   - u16 カラム位置・トークン長
//!   - u32 行番号・コレクション要素数
//!   - u64 NaN-boxed Value・ハッシュ値
//!   - usize スライス長・配列インデックス
//!   - i32 / i64 符号付き整数
//!   - f64 Clojure 浮動小数
//!   - bool 真偽値
//!   - void 値を返さない関数の戻り値
//!
//! `@sizeOf(T)` は型のバイトサイズをコンパイル時に取得する組込関数。
//! 詳細は第 6 章で再登場する。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/03-primitive-types.zig`

const std = @import("std");

pub fn main() !void {
    // 数値リテラルは `_` で桁区切りができる。第 4 章で詳しく扱う
    const a: u8 = 255;
    const b: u32 = 1_000_000;
    const c: i64 = -1_234_567_890_123;
    const d: usize = @sizeOf(u64);
    const e: f64 = 3.14159265358979;
    // 比較演算子の結果は bool になる
    const f: bool = a < b;

    std.debug.print("[03] u8  max value      : {d}\n", .{a});
    std.debug.print("[03] u32 underscored    : {d}\n", .{b});
    std.debug.print("[03] i64 negative       : {d}\n", .{c});
    std.debug.print("[03] @sizeOf(u64)       : {d}\n", .{d});
    std.debug.print("[03] f64 pi             : {d}\n", .{e});
    std.debug.print("[03] bool (a < b)       : {}\n", .{f});

    // `void` は唯一の値 `{}` を持つ型。値を返さない関数の戻り値型に使う。
    // `_ = expr;` は「式の結果を捨てる」明示的な書き方
    const nothing: void = {};
    _ = nothing;
    std.debug.print("[03] void value         : (出力なしが正常です)\n", .{});
}
