//! 08: スライス

const std = @import("std");

/// 関数引数の型: []const u8 <= 文字列リテラル・配列スライス両対応
fn lengthOf(s: []const u8) usize {
    return s.len;
}

pub fn main() !void {
    const buffer: [10]u8 = .{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'C', 'L', 'J' };

    const all: []const u8 = buffer[0..]; // [0..]で最初から残りのスライス(=すべて)
    std.debug.print("[08] all ({d} bytes) : {s}\n", .{ all.len, all });

    const head: []const u8 = buffer[0..5]; // [0..5]、ちなみに、[..5]は無効。できない
    std.debug.print("[08] head ({d} bytes) : {s}\n", .{ head.len, head });

    const tail: []const u8 = buffer[7..]; // [7..]
    std.debug.print("[08] tail ({d} bytes) : {s}\n", .{ tail.len, tail });

    const lit: []const u8 = "hello";
    std.debug.print("[08] lengthOf(lit) : {d}\n", .{lengthOf(lit)});

    // 可変スライス(constなしの[]T)
    var nums: [5]i32 = .{ 1, 2, 3, 4, 5 };
    const view: []i32 = nums[1..4];
    view[0] = 99; // []i32スライスを介して元のnumsを書き変えられる
    std.debug.print("[08] mutated nums : {any}\n", .{nums});
}
