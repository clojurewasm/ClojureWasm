//! 03: 基本型

const std = @import("std");

pub fn main() !void {
    const a: u8 = 255;
    const b: u32 = 1_000_000;
    const c: i64 = -1_234_567_890_123;
    const d: usize = @sizeOf(u64);
    const e: f64 = 3.14159265358979;
    const f: bool = a < b;

    std.debug.print("[03] u8  max value      : {d}\n", .{a});
    std.debug.print("[03] u32 underscored    : {d}\n", .{b});
    std.debug.print("[03] i64 negative       : {d}\n", .{c});
    std.debug.print("[03] @sizeOf(u64)       : {d}\n", .{d});
    std.debug.print("[03] f64 pi             : {d}\n", .{e});
    std.debug.print("[03] bool (a < b)       : {}\n", .{f});

    const nothing: void = {};
    _ = nothing; // 「式の結果を捨てる」も明示しなければならない
    std.debug.print("[03] void value         : 出力なしが正常です\n", .{});
}
