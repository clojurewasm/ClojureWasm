//! 27: テストブロック — `test "name" { ... }`
//!
//! Zig はテストをコードと同じファイルに書く。`zig test <file>` を
//! 実行するとファイル内のすべての `test` ブロックが実行される。
//! 本リポジトリは `src/main.zig` の最後に `test { _ = @import("..."); ... }`
//! を書いて、`zig build test` 一発で全テストを発見させる構成。
//!
//! アサーションは `std.testing.expect(cond)` を主に使う（本リポジトリの
//! 慣習）。`try` を前置して、条件が偽ならテスト失敗のエラーが返る。
//!
//! 実行方法 (プログラムとして): `zig run docs/ja/learn_zig/samples/27_tests.zig`
//! 実行方法 (テストとして)    : `zig test docs/ja/learn_zig/samples/27_tests.zig`

const std = @import("std");

fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

// `pub fn main` は `zig run` で実行される。テストブロックは `zig test` で
// しか走らないので、両方の入口で動作を確認できるようにしておく
pub fn main() !void {
    std.debug.print("[27] zig run なのでアサーションをインラインで実行する\n", .{});
    std.debug.assert(add(2, 3) == 5);
    std.debug.assert(maxOf(i32, 7, 4) == 7);
    std.debug.assert(maxOf(f64, 1.5, 2.5) == 2.5);
    std.debug.print("[27] asserts passed\n", .{});
    std.debug.print("[27] テストブロックは `zig test` で実行される\n", .{});
}

// `test "name" { ... }` ブロックは `zig test` の対象。`std.testing.expect(cond)`
// が本リポジトリの基本イディオム
test "add: small integers" {
    try std.testing.expect(add(2, 3) == 5);
    try std.testing.expect(add(-1, 1) == 0);
}

test "maxOf: works for i32 and f64" {
    try std.testing.expect(maxOf(i32, 7, 4) == 7);
    try std.testing.expect(maxOf(f64, 1.5, 2.5) == 2.5);
}
