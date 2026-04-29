//! 15: タグ付き union — `union(enum)`
//!
//! `union(enum)` はタグ enum をコンパイラが自動生成してくれる
//! タグ付き共用体。本リポジトリの `Node`（`eval/node.zig`）と
//! `FormData`（`eval/form.zig`）が代表例で、`switch` による網羅
//! ディスパッチが backend の中心装置になっている。
//!
//! `switch` で捕捉する `|v|` は payload の値、`|*p|` ならポインタ。
//! 全分岐で同じフィールドにアクセスしたい場合は `inline else => |n| ...`
//! を使うと、コンパイラが各分岐を順次インライン展開してくれる
//! （`Node.loc()` の実装で使われている）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/15-tagged-union.zig`

const std = @import("std");

/// タグ付き union。タグ enum 名は `Node.Tag` として自動生成される
const Node = union(enum) {
    integer: i64,
    name: []const u8,
    pair: Pair,

    const Pair = struct { lhs: i64, rhs: i64 };

    /// 共通サブフィールドへのアクセスを `inline else` でまとめる例。
    /// 各 variant が同じ名前のフィールドを持つときに有効
    pub fn label(self: Node) []const u8 {
        return switch (self) {
            .integer => "integer",
            .name => "name",
            .pair => "pair",
        };
    }
};

pub fn main() !void {
    // タグ付き union のリテラルは `.{ .tag = payload }`
    const items = [_]Node{
        .{ .integer = 42 },
        .{ .name = "hello" },
        .{ .pair = .{ .lhs = 3, .rhs = 4 } },
    };

    for (items) |n| {
        // payload を `|v|` で捕捉して分岐ごとに別の処理を書く
        switch (n) {
            .integer => |v| std.debug.print("[15] {s:<8} : int={d}\n", .{ n.label(), v }),
            .name => |s| std.debug.print("[15] {s:<8} : name={s}\n", .{ n.label(), s }),
            .pair => |p| std.debug.print(
                "[15] {s:<8} : pair=({d},{d})\n",
                .{ n.label(), p.lhs, p.rhs },
            ),
        }
    }
}
