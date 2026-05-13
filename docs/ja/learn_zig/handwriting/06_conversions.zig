//! 06: 明示的な型変換 Zigでは特にメモリサイズも型も暗黙的な変換は許していない

const std = @import("std");

pub fn main() !void {
    const a = @as(i64, 42); // 明示的型キャスト
    std.debug.print("[06] @as(i64, 42) : {d}\n", .{a});

    const b: u16 = @intCast(a); // 縮小キャスト
    std.debug.print("[06] @intCast → u16 : {d}\n", .{b});

    const big: u64 = 0xDEAD_BEEF_CAFE_BABE;
    const low16: u16 = @truncate(big); // 上位ビット捨てる
    std.debug.print("[06] @truncate(big) : 0x{X}\n", .{low16});

    const i: i64 = 7;
    const f: f64 = @floatFromInt(i); // 整数 => 浮動小数点数
    std.debug.print("[06] @floatFromInt(7) : {e}\n", .{f});

    const bits: u64 = @bitCast(@as(f64, 1.5)); // 同じサイズでbitパターンを違う型として再解釈
    std.debug.print("[06] @bitCast(1.5) : 0x{X:0>16}\n", .{bits});

    const truthy: u8 = @intFromBool(true); // 真偽値 => 整数
    const falsy: u8 = @intFromBool(false);
    std.debug.print("[06] @intFromBool(true) → u8 : {d}\n", .{truthy});
    std.debug.print("[06] @intFromBool(false) → u8 : {d}\n", .{falsy});

    std.debug.print("[06] @sizeOf(u64) : {d}\n", .{@sizeOf(u64)}); // サイズ(byte)
    std.debug.print("[06] @sizeOf(f64) : {d}\n", .{@sizeOf(f64)}); // サイズ(byte)
    std.debug.print("[06] @alignOf(u64) : {d}\n", .{@alignOf(u64)}); // アラインメント要求
    // メモリ配置を8の倍数にするなどして効率化
}
