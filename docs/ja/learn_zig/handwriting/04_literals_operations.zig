//! 04: 数値リテラルと演算子

const std = @import("std");

pub fn main() !void {
    const tag: u64 = 0xFFFC_0000_0000_0000; // 16進数
    const payload: u64 = 1_234_567;
    const packed_value: u64 = tag | payload;
    const top16: u16 = @truncate(packed_value >> 48);
    const masked: u64 = packed_value & 0x0000_FFFF_FFFF_FFFF;
    const sum: i32 = 2 + 3 * 4;
    const div: i32 = 17 / 5;
    const rem: i32 = 17 % 5;

    const eq: bool = sum == 14;
    const ne: bool = div != rem;

    std.debug.print("[04] tag | payload    : 0x{X:0>16}\n", .{packed_value});
    std.debug.print("[04] top16 (>> 48)    : 0x{X}\n", .{top16});
    std.debug.print("[04] payload (& mask) : {d}\n", .{masked});
    std.debug.print("[04] sum: 2 + 3 * 4 = {d}\n", .{sum});
    std.debug.print("[04] div: 17 / 4 = {d}\n", .{div});
    std.debug.print("[04] rem: 17 % 5 = {d}\n", .{rem});
    std.debug.print("[04] sum == 14 = {}\n", .{eq});
    std.debug.print("[04] div != rem = {}\n", .{ne});
}
