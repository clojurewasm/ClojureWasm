//! 29: `std.fmt` — `bufPrint` / `parseInt` / `parseFloat`
//!
//! 本リポジトリで使われている整形・解析関数:
//!   - `std.fmt.bufPrint(buf, fmt, args)` — 固定バッファに書き出して
//!     `[]u8` を返す。`runtime/error.zig` の `setErrorFmt` の核。
//!   - `std.fmt.parseInt(T, s, base)` — 整数リテラル解析
//!   - `std.fmt.parseFloat(T, s)`     — 浮動小数リテラル解析
//!   - `std.fmt.allocPrint(alloc, fmt, args)` — アロケータに `[]u8`
//!     を確保してフォーマット（本リポジトリでも数か所使用）
//!
//! 主なフォーマット指定子:
//!   {s}     文字列 ([]const u8)
//!   {d}     整数 / 浮動小数を 10 進
//!   {x} {X} 16 進（X は大文字）
//!   {?d}    optional な整数（null は "null" と表示される）
//!   {any}   構造体のデバッグ表示
//!   {:0>16} 幅 16・0 パディング
//!   {d:.2}  浮動小数 2 桁
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/29_format_parse.zig`

const std = @import("std");

pub fn main() !void {
    var buf: [64]u8 = undefined;

    // (1) bufPrint — 固定バッファに書き出す。戻り値は実際に書かれた
    // 部分のスライス。バッファ不足なら error.NoSpaceLeft が返る
    const msg = try std.fmt.bufPrint(&buf, "{s}: count={d} ratio={d:.2}", .{
        "<-e>", 17, 0.4321,
    });
    std.debug.print("[29] bufPrint           : {s}\n", .{msg});

    // (2) parseInt — 進数を第 3 引数で指定
    const n_dec = try std.fmt.parseInt(i64, "12345", 10);
    const n_hex = try std.fmt.parseInt(u64, "DEADBEEF", 16);
    std.debug.print("[29] parseInt dec       : {d}\n", .{n_dec});
    std.debug.print("[29] parseInt hex       : 0x{X}\n", .{n_hex});

    // (3) parseFloat
    const f = try std.fmt.parseFloat(f64, "2.71828");
    std.debug.print("[29] parseFloat         : {d}\n", .{f});

    // (4) 失敗ケース — `if (result) |v| ... else |err| ...` で
    //     成功・失敗を分岐する書き方
    const bad = std.fmt.parseInt(i64, "not-a-number", 10);
    if (bad) |_| unreachable else |err| {
        std.debug.print("[29] parseInt(bad) err  : {s}\n", .{@errorName(err)});
    }
}
