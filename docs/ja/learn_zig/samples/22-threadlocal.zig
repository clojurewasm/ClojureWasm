//! 22: `threadlocal var`
//!
//! スレッドごとに独立したインスタンスを持つグローバル変数。Phase 1 の
//! 本リポジトリはシングルスレッドだが、`runtime/error.zig` の
//! `last_error: ?Info` / `msg_buf: [512]u8` / `call_stack` はすでに
//! threadlocal で宣言されている。そうすれば Phase 15 で並列化したとき、
//! ロックを足さずにスレッドごとに自然分離されるという狙い。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/22-threadlocal.zig`

const std = @import("std");

// `threadlocal var` はスレッドローカル。同一スレッド内では普通の
// グローバル変数のように振る舞う
threadlocal var depth: u32 = 0;
threadlocal var last_msg: ?[]const u8 = null;

fn enter(name: []const u8) void {
    depth += 1;
    last_msg = name;
    std.debug.print("[22] enter({s}) depth={d}\n", .{ name, depth });
}

fn leave() void {
    std.debug.print("[22] leave depth={d}\n", .{depth});
    depth -= 1;
}

pub fn main() !void {
    std.debug.print("[22] initial depth      : {d}\n", .{depth});
    std.debug.print("[22] last_msg before    : {s}\n", .{last_msg orelse "(null)"});

    // ネストしたスタック push / pop。本リポジトリの `call_stack` /
    // `stack_depth` の動きと同じ
    enter("read");
    enter("analyse");
    enter("eval");
    leave();
    leave();
    leave();

    std.debug.print("[22] last_msg after     : {s}\n", .{last_msg orelse "(null)"});
}
