//! 05: `const` と `var` — 不変・可変・型推論
//!
//! Zig は不変がデフォルト。`const` を主役に据え、`var` は本当に
//! 再代入が必要な箇所だけに使う。型注釈は省略可能（型推論される）
//! だが、本リポジトリは関数の境界を越える値や struct のフィールドに
//! は必ず注釈を付ける方針。
//!
//! 注: ループ構文 `while` は第 11 章で本格的に扱うが、`var` の
//! 再代入の動きを見るために最後だけ前借りで登場させる。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/05_const_var.zig`

const std = @import("std");

pub fn main() !void {
    // const: 再代入できない。型は推論される
    const greeting = "hi";
    // const + 型注釈
    const max_iter: u32 = 100;

    // var: 再代入できる。初期化は必須（または `undefined` で「あとで埋める」）
    var counter: u32 = 0;
    counter = counter + 1;
    counter += 5;

    std.debug.print("[05] greeting           : {s}\n", .{greeting});
    std.debug.print("[05] max_iter (const)   : {d}\n", .{max_iter});
    std.debug.print("[05] counter (var)      : {d}\n", .{counter});

    // 配列は var に束縛すれば要素を書き換えられる（第 7 章で詳述）
    var arr: [3]i32 = .{ 10, 20, 30 };
    arr[1] = 99;
    std.debug.print("[05] mutated arr        : {any}\n", .{arr});

    // 第 11 章の予告: while ループによる繰り返しも var の典型例
    var tick: u32 = 0;
    while (tick < 3) : (tick += 1) {
        std.debug.print("[05] tick               : {d}\n", .{tick});
    }
}
