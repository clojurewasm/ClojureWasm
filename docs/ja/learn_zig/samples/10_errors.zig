//! 10: エラーと error union — `error{ ... }` / `!T` / `try` / `catch`
//!     / `defer` / `errdefer`
//!
//! Zig のエラーは「値」。`error{ Foo, Bar }` がエラー集合の宣言、`!T`
//! が「エラー or T」を表す error union 型のショートカット。本リポジトリの
//! `runtime/error.zig` は `Error = error{ SyntaxError, NumberError, ... }`
//! を 13 タグで宣言し、`anyerror!Value` を全フェーズの戻り値型に
//! 揃えている（`anyerror` は第 30 章）。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/10_errors.zig`

const std = @import("std");

// 自前のエラー集合
const ParseError = error{
    Empty,
    NotANumber,
    Overflow,
};

// 戻り値型 `ParseError!u32` は「ParseError か u32」のどちらか
fn parsePositive(s: []const u8) ParseError!u32 {
    if (s.len == 0) return ParseError.Empty;
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return ParseError.NotANumber;
        const digit: u32 = c - '0';
        // u32 のオーバーフローを早めに検出する
        if (n > (std.math.maxInt(u32) - digit) / 10) return ParseError.Overflow;
        n = n * 10 + digit;
    }
    return n;
}

fn doubleIt(s: []const u8) ParseError!u32 {
    // `try` — エラーならそのまま伝搬し、成功なら値を取り出す
    const n = try parsePositive(s);
    if (n > std.math.maxInt(u32) / 2) return ParseError.Overflow;
    return n * 2;
}

pub fn main() !void {
    // `defer`: スコープを抜けるとき、成功・失敗いずれでも必ず実行
    defer std.debug.print("[10] defer fires last\n", .{});

    // `errdefer`: スコープがエラーで抜けたときだけ実行。リソース確保中の
    // 巻き戻しに使う。本リポジトリの `Env.intern` などが代表例
    errdefer std.debug.print("[10] errdefer は今回エラーが出ていないので発火しない\n", .{});

    // `catch <expr>` — エラー時の既定値を後置で指定
    const fallback = doubleIt("xyz") catch @as(u32, 0);
    std.debug.print("[10] doubleIt(xyz) catch: {d}\n", .{fallback});

    // `catch |err| { ... }` — エラータグを捕捉してハンドリング。
    // 戻り値が必要ならラベル付きブロック（→ 第 12 章）を併用する。
    // `@errorName(err)` はエラータグ名を文字列化する組込関数（→ 第 30 章）
    const result = doubleIt("21") catch |err| blk: {
        std.debug.print("[10] unexpected: {s}\n", .{@errorName(err)});
        break :blk @as(u32, 0);
    };
    std.debug.print("[10] doubleIt(21)       : {d}\n", .{result});

    // `try` を main 直下で使うと、`!void` の戻り値経由で OS まで
    // エラーが伝搬する
    const big = try doubleIt("100");
    std.debug.print("[10] doubleIt(100)      : {d}\n", .{big});
}
