//! 28: `std.mem` ユーティリティと `@memcpy`
//!
//! 本リポジトリで実際に使われているスライス操作:
//!   - `std.mem.eql(T, a, b)`               2 つのスライスが等しいか
//!   - `std.mem.startsWith(T, hay, prefix)` 接頭辞かどうか
//!   - `std.mem.indexOf(T, hay, needle)`    部分列の最初の位置 `?usize`
//!   - `std.mem.indexOfScalar(T, hay, c)`   単一要素の最初の位置 `?usize`
//!   - `@memcpy(dst, src)`                  バッファコピー（同サイズ必須）
//!
//! `main.zig` の argv 解析は `std.mem.eql(u8, arg, "-h")` を多用、
//! `tokenizer.zig` は `indexOfScalar` を使う。`runtime/error.zig` の
//! `setErrorFmt` はバッファ末尾の "..." 切り詰めマーカに `@memcpy` を
//! 使っている。
//!
//! 注: `@memset` は本リポジトリ未使用なので扱わない。バッファを初期化
//!     したい場合は `for (slice) |*c| c.* = ...` か、用途上アロケータ
//!     の `dupe` で済むことが多い。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/28-mem-utilities.zig`

const std = @import("std");

pub fn main() !void {
    const a = "hello";
    const b = "hello";
    const c = "world";

    // スライス内容比較
    std.debug.print("[28] eql(a,b)           : {}\n", .{std.mem.eql(u8, a, b)});
    std.debug.print("[28] eql(a,c)           : {}\n", .{std.mem.eql(u8, a, c)});

    // 接頭辞検査
    std.debug.print("[28] startsWith 'hel'   : {}\n", .{std.mem.startsWith(u8, a, "hel")});
    std.debug.print("[28] startsWith 'wor'   : {}\n", .{std.mem.startsWith(u8, a, "wor")});

    // 単一要素検索 — `?usize` を返すので optional 解放する
    if (std.mem.indexOfScalar(u8, "abcdef", 'd')) |i| {
        std.debug.print("[28] indexOfScalar 'd'  : {d}\n", .{i});
    }

    // 部分列検索
    if (std.mem.indexOf(u8, "the quick brown fox", "brown")) |i| {
        std.debug.print("[28] indexOf 'brown'    : {d}\n", .{i});
    }

    // `@memcpy` — 本リポジトリの `setErrorFmt` のように、固定バッファに
    // 短いマーカを書き込む用途
    var buf: [8]u8 = .{ '.', '.', '.', '.', '.', '.', '.', '.' };
    @memcpy(buf[0..3], "Zig");
    std.debug.print("[28] @memcpy('Zig')     : {s}\n", .{&buf});
}
