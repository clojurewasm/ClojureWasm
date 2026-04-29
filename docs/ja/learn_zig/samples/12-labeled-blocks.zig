//! 12: ラベル付きブロック — `blk: { break :blk value; }`
//!
//! ラベルを付けたブロックは「値を返す式」になる。`break :label value` で
//! ブロック脱出と値返しを兼ねる。本リポジトリで多用されている形は
//! 2 つ:
//!   1. 三項分岐の長い枝を畳む
//!      `const x = if (cond) y else blk: { ... break :blk z; };`
//!   2. catch ハンドラ内で復帰値を作る
//!      `bufPrint(...) catch blk: { @memcpy(...); break :blk fallback; };`
//!
//! 注: 本リポジトリは `blk:` ラベルしか使っていない（labeled `for` /
//!     `while` のループラベルは登場しない）ので、本サンプルもブロック
//!     ラベルだけに絞る。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/12-labeled-blocks.zig`

const std = @import("std");

pub fn main() !void {
    // (1) ラベル付きブロックを式として使う
    const greeting: []const u8 = blk: {
        const hour: u8 = 9;
        if (hour < 12) break :blk "good morning";
        if (hour < 18) break :blk "good afternoon";
        break :blk "good evening";
    };
    std.debug.print("[12] greeting           : {s}\n", .{greeting});

    // (2) `catch blk: { ... }` の復帰値生成。`runtime/error.zig` の
    // `setErrorFmt` がまさにこの形 — `bufPrint` がバッファ不足で
    // 失敗したとき、末尾に "..." を書いて切り詰めた値を返す
    var buf: [16]u8 = undefined;
    const msg: []const u8 = std.fmt.bufPrint(&buf, "n={d}", .{99}) catch blk: {
        break :blk "fmt-overflow";
    };
    std.debug.print("[12] msg                : {s}\n", .{msg});

    // (3) ブロックの中で複数の局所値を組み立てて最終的に 1 つを返す
    const score: i32 = blk: {
        const base: i32 = 10;
        const bonus: i32 = 3;
        const penalty: i32 = 1;
        break :blk base + bonus - penalty;
    };
    std.debug.print("[12] score              : {d}\n", .{score});
}
