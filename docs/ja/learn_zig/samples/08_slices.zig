//! 08: スライス — `[]T` / `[]const T` / 配列からのスライス取得
//!
//! スライスは「ポインタ + 長さ」のペア。`[]const u8` は本リポジトリで
//! 「文字列」を表す標準的な型で、すべての `name` / `message` /
//! `[]const u8` フィールドはどこかの所有領域への参照ビューになっている。
//!
//! `[start..end]` で配列やスライスから部分スライスを切り出す。
//! `[start..]` は末尾まで、`[..end]` は先頭から。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/08_slices.zig`

const std = @import("std");

// 関数引数を `[]const u8` にすれば、文字列リテラルも配列のスライスも
// そのまま渡せる
fn lengthOf(s: []const u8) usize {
    return s.len;
}

pub fn main() !void {
    const buffer: [10]u8 = .{ 'H', 'e', 'l', 'l', 'o', ',', ' ', 'C', 'L', 'J' };

    // `[start..end]` で部分スライスを取り出す
    const all: []const u8 = buffer[0..];
    const head: []const u8 = buffer[0..5];
    const tail: []const u8 = buffer[7..];

    std.debug.print("[08] all   ({d} bytes) : {s}\n", .{ all.len, all });
    std.debug.print("[08] head  ({d} bytes) : {s}\n", .{ head.len, head });
    std.debug.print("[08] tail  ({d} bytes) : {s}\n", .{ tail.len, tail });

    // 文字列リテラルは厳密には `*const [N:0]u8` 型（null 終端付き
    // 固定長配列へのポインタ）。`[]const u8` への暗黙変換が効く
    const lit: []const u8 = "hello";
    std.debug.print("[08] lengthOf(lit)      : {d}\n", .{lengthOf(lit)});

    // 可変スライス `[]T` を取れば、元配列の中身を書き換えられる
    var nums: [5]i32 = .{ 1, 2, 3, 4, 5 };
    const view: []i32 = nums[1..4];
    view[0] = 99; // nums[1] に書き戻る
    std.debug.print("[08] mutated nums       : {any}\n", .{nums});
}
