//! 19: `comptime` / `inline for` / `anytype`
//!
//! - `comptime` はコンパイル時評価を表すキーワード。値・式・関数引数
//!   ・block の各位置で使える
//! - `inline for` はコンパイル時に既知の配列を **アンロール** する
//!   ループ。本リポジトリの primitive 登録（`lang/primitive/core.zig`
//!   の `inline for (ENTRIES) |it| ...`）が代表例
//! - `anytype` は呼び出し時の型を後付けで決める ad-hoc ジェネリクス。
//!   本リポジトリでは `args: anytype`（`runtime/error.zig` の
//!   `setErrorFmt(comptime fmt, args: anytype)`）や `ptr: anytype`
//!   （`Value.encodeHeapPtr(ht, ptr: anytype)`）で使われている
//!
//! 注: `std.Io.Writer` を引数に取る anytype 例は第 26 章まで温存する。
//!     本サンプルは `args: anytype` を `std.fmt.bufPrint` に転送する形
//!     （本リポジトリの `setErrorFmt` と同じイディオム）にする。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/19_comptime_anytype.zig`

const std = @import("std");

/// `comptime T: type` ジェネリクス — 呼び出しごとに型 T が固定される
fn maxOf(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

/// `comptime pred: fn (...) bool` — `lang/primitive/math.zig` の
/// `pairwise` と同じイディオム。比較関数を comptime で受け、
/// その関数を内部で呼び出す
fn allPairs(
    comptime T: type,
    items: []const T,
    comptime pred: fn (a: T, b: T) bool,
) bool {
    if (items.len < 2) return true;
    var i: usize = 0;
    while (i + 1 < items.len) : (i += 1) {
        if (!pred(items[i], items[i + 1])) return false;
    }
    return true;
}

fn lessThan(a: i32, b: i32) bool {
    return a < b;
}

/// `args: anytype` を `std.fmt.bufPrint` にそのまま転送するパターン。
/// 本リポジトリの `setErrorFmt` と同じ形
fn formatToBuf(buf: []u8, comptime fmt: []const u8, args: anytype) ![]u8 {
    return std.fmt.bufPrint(buf, fmt, args);
}

/// `inline for` を回す対象テーブル
const Entry = struct { name: []const u8, value: i32 };
const ENTRIES = [_]Entry{
    .{ .name = "one", .value = 1 },
    .{ .name = "two", .value = 2 },
    .{ .name = "three", .value = 3 },
};

pub fn main() !void {
    // (1) comptime 評価された定数
    const SIZE = comptime @sizeOf(u64) * 2;
    std.debug.print("[19] comptime SIZE      : {d}\n", .{SIZE});

    // (2) `comptime T: type` ジェネリクス — 各呼び出しがモノモルフ化される
    std.debug.print("[19] maxOf(i32) 3,7     : {d}\n", .{maxOf(i32, 3, 7)});
    std.debug.print("[19] maxOf(f64) 1.5,0.9 : {d}\n", .{maxOf(f64, 1.5, 0.9)});

    // (3) `comptime pred: fn(...)` で比較関数を渡す
    const sorted = [_]i32{ 1, 2, 3, 4 };
    const unsorted = [_]i32{ 1, 3, 2 };
    std.debug.print("[19] allPairs(<) sorted : {}\n", .{allPairs(i32, &sorted, lessThan)});
    std.debug.print("[19] allPairs(<) unsort : {}\n", .{allPairs(i32, &unsorted, lessThan)});

    // (4) `inline for` — ループ本体が comptime 既知の各要素分インライン展開される
    inline for (ENTRIES) |it| {
        std.debug.print("[19] entry              : {s}={d}\n", .{ it.name, it.value });
    }

    // (5) `args: anytype` — タプル要素の型はバラバラでよい
    var buf: [64]u8 = undefined;
    const out1 = try formatToBuf(&buf, "name={s} count={d}", .{ "alpha", 7 });
    std.debug.print("[19] anytype tuple #1   : {s}\n", .{out1});

    var buf2: [64]u8 = undefined;
    const out2 = try formatToBuf(&buf2, "ratio={d:.2} flag={}", .{ 0.345, true });
    std.debug.print("[19] anytype tuple #2   : {s}\n", .{out2});
}
