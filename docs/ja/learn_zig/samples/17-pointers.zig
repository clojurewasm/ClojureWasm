//! 17: ポインタと `anyopaque`
//!
//! Zig のポインタは複数種類:
//!   - `*T`         単一要素ポインタ
//!   - `*const T`   読み取り専用
//!   - `[*]T`       多要素ポインタ（C の `T*` 相当、長さ非保持）
//!   - `?*T`        nullable ポインタ
//!   - `*anyopaque` 型消去ポインタ（C の `void*` 相当）
//!
//! 参照外しは `p.*`、アドレス取得は `&x`。
//!
//! 本リポジトリでは `runtime/gc/arena.zig` の allocator vtable コール
//! バックが `ctx: *anyopaque` を受け取り、`@ptrCast(@alignCast(ctx))`
//! で具体型 `*ArenaGc` に復元するパターンが教科書例。NaN ボックスの
//! 値エンコードは `@intFromPtr` / `@ptrFromInt` でポインタを 48 bit
//! 整数に往復させている。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/17-pointers.zig`

const std = @import("std");

// `*u32` で受ければポインタ越しに書き換えられる
fn bumpThrough(p: *u32) void {
    p.* += 1;
}

// `*const u32` は読み取り専用ポインタ
fn readOnly(p: *const u32) u32 {
    return p.*;
}

/// 型消去ポインタを受け取り、具体型に復元するパターン。
/// `runtime/gc/arena.zig` の `arenaAlloc` がこの形
const Counter = struct {
    n: u32,

    fn bump(ctx: *anyopaque) void {
        // `@ptrCast(@alignCast(ctx))` の入れ子は本リポジトリ全域の慣例。
        // `@alignCast` でアラインメント情報を `*Counter` 相当に揃え、
        // `@ptrCast` で型を付け替える
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.n += 1;
    }
};

pub fn main() !void {
    var x: u32 = 10;
    // `&x` は `*u32` を返す。ポインタ越しに書き換える
    const px: *u32 = &x;
    bumpThrough(px);
    bumpThrough(px);
    std.debug.print("[17] x after 2 bumps    : {d}\n", .{x});

    // 読み取り専用ポインタ
    const cx: *const u32 = &x;
    std.debug.print("[17] readOnly(cx)       : {d}\n", .{readOnly(cx)});

    // ポインタ ↔ 整数の往復。NaN ボックスでアドレスを 48 bit に詰める
    // ときの中核
    const addr: usize = @intFromPtr(&x);
    const back: *u32 = @ptrFromInt(addr);
    std.debug.print("[17] addr % @alignOf    : {d}\n", .{addr % @alignOf(u32)});
    std.debug.print("[17] *back              : {d}\n", .{back.*});

    // `*anyopaque` 経由のコールバック呼び出し
    var ctr: Counter = .{ .n = 0 };
    Counter.bump(&ctr);
    Counter.bump(&ctr);
    Counter.bump(&ctr);
    std.debug.print("[17] ctr.n after 3 bumps: {d}\n", .{ctr.n});
}
