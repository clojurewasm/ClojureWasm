//! 18: 関数と関数ポインタ — vtable パターン
//!
//! Zig の関数は第一級。関数ポインタの型は `*const fn(args) Return`。
//! 本リポジトリの中核イディオム「Layer 0 は型のみ宣言し、Layer 1 が
//! 起動時に関数を流し込む」は、struct のフィールドに関数ポインタを
//! 置くこと（vtable）で実現している（`runtime/dispatch.zig`）:
//!
//!     pub const VTable = struct {
//!         callFn: CallFn,                  // *const fn(...) anyerror!Value
//!         valueTypeKey: ValueTypeKeyFn,    // *const fn(Value) []const u8
//!     };
//!
//! `Runtime.vtable: ?VTable` にしておくことで、複数の Runtime が
//! 別の backend を持てる（テストでのモック注入も可）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/18_functions_fnptr.zig`

const std = @import("std");

// ふつうの関数定義
fn add(a: i32, b: i32) i32 {
    return a + b;
}

fn sub(a: i32, b: i32) i32 {
    return a - b;
}

// 関数ポインタ型のエイリアス
const BinaryOp = *const fn (i32, i32) i32;

// vtable パターン — struct に関数ポインタを並べる
const VTable = struct {
    add: BinaryOp,
    sub: BinaryOp,
};

// 関数ポインタを引数で受け、内部で 2 回呼ぶ
fn applyTwice(op: BinaryOp, a: i32, b: i32) i32 {
    const x = op(a, b);
    return op(x, b);
}

pub fn main() !void {
    // vtable のインスタンスを作って、フィールド経由で間接呼び出し
    const vt: VTable = .{ .add = add, .sub = sub };

    std.debug.print("[18] vt.add(2,3)        : {d}\n", .{vt.add(2, 3)});
    std.debug.print("[18] vt.sub(10,4)       : {d}\n", .{vt.sub(10, 4)});

    // 関数ポインタを引数として渡す
    std.debug.print("[18] applyTwice(add)    : {d}\n", .{applyTwice(add, 1, 1)}); // ((1+1)+1) = 3
    std.debug.print("[18] applyTwice(sub)    : {d}\n", .{applyTwice(sub, 10, 1)}); // ((10-1)-1) = 8

    // 関数ポインタは普通の値なので、条件式で選択もできる
    const f: BinaryOp = if (true) add else sub;
    std.debug.print("[18] f(7,8)             : {d}\n", .{f(7, 8)});
}
