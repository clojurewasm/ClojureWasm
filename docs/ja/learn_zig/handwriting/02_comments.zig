//! 02: コメント

const std = @import("std");

/// `square(x)`はxの二乗を返す
fn square(x: i32) i32 {
    return x * x;
}

pub fn main() !void {
    std.debug.print("[02] square(7) = {d}\n", .{square(7)});
    std.debug.print("'//!' = モジュールドキュメントコメント\n", .{});
    std.debug.print("'///' = 宣言ドキュメントコメント\n", .{});
    std.debug.print("'//'  = 1行コメント\n", .{});
}
