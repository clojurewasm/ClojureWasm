//! 14: `enum` — 通常 enum / 整数バックエンド付き enum / 非網羅 enum
//!
//! enum 関連の組込関数 `@intFromEnum` / `@enumFromInt` / `@tagName` を
//! ここでまとめて扱う（第 6 章で「enum 関連は 14 章で」と予告した分）。
//!
//! 本リポジトリでは:
//!   - `HeapTag = enum(u8) { string = 0, ..., @"volatile" }`
//!     32 個の heap object 種別を 8 bit に詰める
//!   - `Value = enum(u64) { nil_val = ..., true_val = ..., false_val = ..., _, }`
//!     非網羅形式（末尾 `_,`）で任意の u64 ビット列を許す（NaN ボクシング）
//!   - `@"volatile"` のエスケープ識別子で Zig 予約語との衝突を回避
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/14-enums.zig`

const std = @import("std");

/// 整数バックエンド付き enum。各タグの整数表現を明示
const HeapTag = enum(u8) {
    string = 0,
    symbol = 1,
    keyword = 2,
    list = 3,
    /// `volatile` は Zig 予約語なので `@"..."` でエスケープする
    @"volatile" = 23,
};

/// 非網羅 enum — 末尾 `_,` で「上に列挙していないビット列も許す」を表す。
/// NaN ボクシングのように「タグそのものが値」のときに使う
const RawByte = enum(u8) {
    zero = 0,
    one = 1,
    _,
};

pub fn main() !void {
    const t: HeapTag = .keyword;

    // enum → 整数（バックエンド型）
    const t_num: u8 = @intFromEnum(t);

    // 整数 → enum。範囲外の値は安全ビルドで panic
    const t_back: HeapTag = @enumFromInt(@as(u8, 23));

    // タグ名の文字列化
    std.debug.print("[14] @tagName(t)        : {s}\n", .{@tagName(t)});
    std.debug.print("[14] @intFromEnum(t)    : {d}\n", .{t_num});
    std.debug.print("[14] @enumFromInt(23)   : {s}\n", .{@tagName(t_back)});

    // 非網羅 enum は任意の u8 を許すので、列挙していない 99 も入る
    const r: RawByte = @enumFromInt(@as(u8, 99));
    std.debug.print("[14] non-exhaustive     : raw={d}\n", .{@intFromEnum(r)});

    // enum に対する switch は網羅必須（タグの取りこぼしがあると
    // コンパイルエラー）。非網羅 enum なら `else =>` を要求される
    const desc = switch (t) {
        .string => "Group A: string",
        .symbol => "Group A: symbol",
        .keyword => "Group A: keyword",
        .list => "Group A: list",
        .@"volatile" => "Group C: volatile",
    };
    std.debug.print("[14] switch desc        : {s}\n", .{desc});
}
