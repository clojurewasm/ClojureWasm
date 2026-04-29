//! 09: オプショナル `?T` — null を型で表す
//!
//! Zig には暗黙の null がない。「null かもしれない」を表すには型として
//! `?T` と書き、使用時に必ずアンラップする。本リポジトリでも
//! `Keyword.ns: ?[]const u8`（unqualified キーワードは ns なし）、
//! `last_error: ?Info`、`current_frame: ?*BindingFrame` のように
//! オプショナルが至るところに登場する。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/09-optionals.zig`

const std = @import("std");

// `?u32` は「値があれば u32、なければ null」の型
fn lookup(name: []const u8) ?u32 {
    if (std.mem.eql(u8, name, "alpha")) return 1;
    if (std.mem.eql(u8, name, "beta")) return 2;
    return null;
}

pub fn main() !void {
    const a: ?u32 = lookup("alpha");
    const z: ?u32 = lookup("zeta");

    // `if (opt) |v| { ... } else { ... }` — payload を捕捉して
    // 非 null の枝に値を持ち込む書き方
    if (a) |v| {
        std.debug.print("[09] alpha → {d}\n", .{v});
    } else {
        std.debug.print("[09] alpha missing\n", .{});
    }

    // `orelse` — null のときの既定値を後置で指定
    const z_or_default: u32 = z orelse 999;
    std.debug.print("[09] zeta orelse 999    : {d}\n", .{z_or_default});

    // `.?` — 非 null を確信しているときのアンラップ。debug ビルドでは
    // null だと panic するので、契約を破ったコードを早期に検出できる
    std.debug.print("[09] alpha .? unwrapped : {d}\n", .{a.?});

    // `orelse <expr>` の右辺はブロック式でも可。本リポジトリの
    // `main.zig` では `expr orelse { ... exit(1); }` の形でエラー
    // 終了経路を畳んでいる。ここではラベル付きブロック（→ 第 12 章）
    // と組み合わせて値を返す形を見せる
    const result = block: {
        const v = lookup("beta") orelse break :block 0;
        break :block v * 10;
    };
    std.debug.print("[09] orelse-break demo  : {d}\n", .{result});

    // null との等価比較もできる（が、`if (z) |v|` の方が自然）
    std.debug.print("[09] z is null          : {}\n", .{z == null});
}
