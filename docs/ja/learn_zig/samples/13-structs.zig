//! 13: `struct` とメソッド — フィールド・デフォルト値・self 系メソッド
//!
//! Zig の `struct` は名前付きフィールドの集合。フィールドにデフォルト
//! 値、メソッドとしてネストした `fn`、定数として `pub const` をぶら
//! 下げられる。本リポジトリの `Tokenizer` / `Env` / `ArenaGc` などは
//! すべて `init` / `deinit` メソッド対の規約に従う。
//!
//! メソッドの第 1 引数の慣習:
//!   - `self: T`        値で受ける（読み取り専用の view）
//!   - `self: *T`       ポインタで受ける（書き換え可・所有）
//!   - `self: *const T` 読み取りビューで受ける（不変参照）
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/13-structs.zig`

const std = @import("std");

/// 統計情報を持つカウンタ。`runtime/gc/arena.zig` の `Stats` 型と
/// 似た形をしている。
const Counter = struct {
    label: []const u8,
    count: u32 = 0, // フィールドのデフォルト値
    bumped_at_least_once: bool = false,

    /// 慣例的なコンストラクタ。アロケータは取らない（ヒープ確保なし）
    pub fn init(label: []const u8) Counter {
        return .{ .label = label };
    }

    /// `*Counter` で受ければフィールドを書き換えられる
    pub fn bump(self: *Counter) void {
        self.count += 1;
        self.bumped_at_least_once = true;
    }

    /// `Counter`（値）で受けると読み取り専用
    pub fn isFresh(self: Counter) bool {
        return self.count == 0;
    }

    /// 読み取り専用ビュー `*const Counter` でも書ける（こちらは
    /// アドレスを取りつつ書き換え不可、という意味）
    pub fn currentValue(self: *const Counter) u32 {
        return self.count;
    }
};

pub fn main() !void {
    // メソッド呼び出しは `c.bump()`。`self` は自動的に `&c` で渡る
    var c = Counter.init("hits");
    c.bump();
    c.bump();
    c.bump();

    // `.{ ... }` リテラルは代入先の型から推論される
    const fresh: Counter = .{ .label = "fresh" };

    std.debug.print("[13] hits.label         : {s}\n", .{c.label});
    std.debug.print("[13] hits.count         : {d}\n", .{c.count});
    std.debug.print("[13] hits.bumped?       : {}\n", .{c.bumped_at_least_once});
    std.debug.print("[13] hits.isFresh()     : {}\n", .{c.isFresh()});
    std.debug.print("[13] hits.currentValue(): {d}\n", .{c.currentValue()});

    std.debug.print("[13] fresh.label        : {s}\n", .{fresh.label});
    std.debug.print("[13] fresh.count        : {d}\n", .{fresh.count});
    std.debug.print("[13] fresh.isFresh()    : {}\n", .{fresh.isFresh()});
}
