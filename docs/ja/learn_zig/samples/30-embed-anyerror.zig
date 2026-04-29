//! 30: `@embedFile` / `anyerror` / `@errorName`
//!
//! - `@embedFile("path")` は指定ファイルの中身をコンパイル時に
//!   `[]const u8` として埋め込む組込関数。本リポジトリは
//!   `clj/clojure/core.clj` を `cljw` バイナリに同梱するために使う:
//!       pub const CORE_SOURCE: []const u8 = @embedFile("clj/clojure/core.clj");
//! - `anyerror` は「いずれかのエラー集合に属する任意のエラー値」を
//!   表す型。本リポジトリは Reader / Analyzer / TreeWalk が異なる
//!   エラー集合を返しても同じ `try` チェーンで運べるよう、公開 API の
//!   戻り値を `anyerror!Value` に揃えてある（`BuiltinFn` がその例）
//! - `@errorName(err)` はエラー値のタグ名を `[]const u8` で返す
//!
//! 本サンプルは自分自身のソースを `@embedFile` で取り込むので、
//! 隣接ファイルへの依存なしで動く（`zig run` 一発で完結）。
//! `@min` も第 6 章では触れていない組込関数だが、本リポジトリの
//! `runtime/keyword.zig` で使われている定番関数（→ コメント参照）
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/30-embed-anyerror.zig`

const std = @import("std");

// 自分自身のソースを埋め込む。Cargo の `include_str!` や Go の
// `//go:embed` に相当する仕組み
const SELF_SOURCE: []const u8 = @embedFile("30-embed-anyerror.zig");

// 別々のエラー集合
const ParseError = error{ Empty, NotANumber };
const IoError = error{Closed};

// `anyerror!void` は「あらゆるエラー集合か void」。`ParseError` も
// `IoError` もそのまま返せる
fn either(flag: bool) anyerror!void {
    if (flag) return ParseError.Empty;
    return IoError.Closed;
}

pub fn main() !void {
    std.debug.print("[30] @embedFile self-len: {d} bytes\n", .{SELF_SOURCE.len});
    // `@min(a, b)` は本リポジトリの `runtime/keyword.zig` の
    // `formatQualified` でも使われている。`@max` も対称形で存在
    std.debug.print("[30] first 60 chars     : {s}\n", .{SELF_SOURCE[0..@min(60, SELF_SOURCE.len)]});

    // anyerror に異なる error set の値を投入できる
    either(true) catch |err| std.debug.print("[30] either(true) err   : {s}\n", .{@errorName(err)});
    either(false) catch |err| std.debug.print("[30] either(false) err  : {s}\n", .{@errorName(err)});

    // 具体的な error set の値も `@errorName` で文字列化できる
    const e: ParseError = ParseError.NotANumber;
    std.debug.print("[30] ParseError tag     : {s}\n", .{@errorName(e)});
}
