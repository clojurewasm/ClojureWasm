//! 06: 明示的な型変換 — `@as` / `@intCast` / `@truncate` / `@bitCast`
//!     / `@floatFromInt` / `@intFromBool` / `@sizeOf` / `@alignOf`
//!
//! Zig は暗黙の縮小変換も符号またぎも float ↔ int の暗黙変換も許さない。
//! すべての型変換は `@`-組込関数で明示する。
//!
//! 本章では「整数・浮動小数・bool・型サイズ」に関わる組込関数だけを
//! 扱う。`@intFromEnum` / `@enumFromInt` / `@tagName` は enum を導入する
//! 第 14 章で、`@intFromPtr` / `@ptrFromInt` / `@ptrCast` / `@alignCast`
//! はポインタを導入する第 17 章で再登場する。`@memcpy` は第 28 章、
//! `@embedFile` / `@errorName` は第 30 章。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/06-conversions.zig`

const std = @import("std");

pub fn main() !void {
    // `@as(T, x)` — 互換型に対する明示的キャスト。最も無害な変換
    const a = @as(i64, 42);

    // `@intCast` — 整数の縮小変換。debug ビルドではレンジチェックあり、
    // 範囲外なら panic。ReleaseFast ではチェックなしで切り捨てる
    const b: u16 = @intCast(a);

    // `@truncate` — レンジチェックなしで上位ビットを捨てる
    const big: u64 = 0xDEAD_BEEF_CAFE_BABE;
    const low16: u16 = @truncate(big);

    // `@floatFromInt` — 整数 → 浮動小数。`@intFromFloat` も対称形で存在
    const i: i64 = 7;
    const f: f64 = @floatFromInt(i);

    // `@bitCast` — 同サイズの型同士で bit パターンを再解釈する
    // 本リポジトリの NaN ボックスでは f64 ↔ u64 の往復に使う
    const bits: u64 = @bitCast(@as(f64, 1.5));

    // `@intFromBool` — bool を 0 / 1 に
    const truthy: u8 = @intFromBool(true);
    const falsy: u8 = @intFromBool(false);

    std.debug.print("[06] @as(i64,42)        : {d}\n", .{a});
    std.debug.print("[06] @intCast → u16     : {d}\n", .{b});
    std.debug.print("[06] @truncate(big)     : 0x{X}\n", .{low16});
    std.debug.print("[06] @floatFromInt(7)   : {d}\n", .{f});
    std.debug.print("[06] @bitCast(1.5)      : 0x{X:0>16}\n", .{bits});
    std.debug.print("[06] @intFromBool t/f   : {d} / {d}\n", .{ truthy, falsy });

    // `@sizeOf(T)` / `@alignOf(T)` — 型サイズとアラインメント要求を
    // コンパイル時に取得する。本リポジトリの `comptime` ブロック内
    // アサーション（`@alignOf(Cons) >= 8` 等）でも頻出
    std.debug.print("[06] @sizeOf(u64)       : {d}\n", .{@sizeOf(u64)});
    std.debug.print("[06] @sizeOf(f64)       : {d}\n", .{@sizeOf(f64)});
    std.debug.print("[06] @alignOf(u64)      : {d}\n", .{@alignOf(u64)});
}
