//! 25: `std.StaticStringMap` — `initComptime` でゼロコストルックアップ
//!
//! コンパイル時に確定する `[]const u8` キー → 値の対応表をコンパイラが
//! 完全ハッシュテーブルとして生成する。実行時のハッシュ計算なしで
//! ルックアップでき、トークナイザの予約語判定や特殊フォーム判定に
//! ぴったり。
//!
//! 本リポジトリでは `runtime/print.zig` のフォーマット指定子テーブル
//! などでこの形が使われる予定（ROADMAP §13 でも推奨）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/25-static-string-map.zig`

const std = @import("std");

const Op = enum { add, sub, mul, div };

// `.{ .{ key, value }, ... }` の形でエントリを並べる
const OPS = std.StaticStringMap(Op).initComptime(.{
    .{ "+", .add },
    .{ "-", .sub },
    .{ "*", .mul },
    .{ "/", .div },
});

// `get` は `?V` を返す。マッチがなければ null
fn classify(sym: []const u8) []const u8 {
    return if (OPS.get(sym)) |op| @tagName(op) else "unknown";
}

pub fn main() !void {
    const samples = [_][]const u8{ "+", "*", "%", "/", "?" };
    for (samples) |s| {
        std.debug.print("[25] {s} → {s}\n", .{ s, classify(s) });
    }
    // `kvs` でテーブル全体にアクセスできる
    std.debug.print("[25] map size           : {d}\n", .{OPS.kvs.len});
}
