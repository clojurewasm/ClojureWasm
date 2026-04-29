//! 21: `undefined` と `unreachable`
//!
//! - `undefined` は「あとで埋めるから初期化しないで」のプレースホルダ。
//!   `bufPrint` などで全面上書きするバッファに使うとゼロ初期化を省ける
//! - `unreachable` は「ここには到達しない」という契約。debug ビルドでは
//!   到達すると panic、ReleaseFast では UB（最適化のヒント）になる。
//!   本リポジトリの `runtime/value.zig` の網羅 switch のフォールバック
//!   `else => unreachable` がまさにこの用法
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/21-undefined-unreachable.zig`

const std = @import("std");

const Group = enum(u8) { a, b, c, d };

fn groupName(g: Group) []const u8 {
    return switch (g) {
        .a => "Group A",
        .b => "Group B",
        .c => "Group C",
        .d => "Group D",
    };
}

// 呼び出し側が「g は 0..3 しか渡さない」と契約しているので、
// それ以外は到達不能と宣言する
fn outOfBand(g: u8) []const u8 {
    return switch (g) {
        0...3 => groupName(@enumFromInt(g)),
        else => unreachable,
    };
}

pub fn main() !void {
    // バッファは bufPrint がすべて上書きするので `undefined` で OK
    var buf: [32]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "n={d}", .{1234});
    std.debug.print("[21] undefined buffer   : len={d} value={s}\n", .{ out.len, out });

    // 契約を満たした呼び出し（`unreachable` には到達しない）
    std.debug.print("[21] outOfBand(2)       : {s}\n", .{outOfBand(2)});

    // ここで `outOfBand(99)` を呼ぶと debug ビルドで panic する。
    // 「ドキュメント兼最適化ヒント」として `unreachable` が機能するのが要点
    std.debug.print("[21] (outOfBand(99) は呼ばない — 呼ぶと panic する)\n", .{});
}
