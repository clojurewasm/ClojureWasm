//! 20: マルチライン文字列リテラル — `\\` 行継続
//!
//! 各行が `\\` で始まり、その行の末尾の改行を含めて連結される。
//! 中ではエスケープ処理が **行われない** ため、`\n` は 2 文字として
//! そのまま入る。引用符やバックスラッシュも素のまま書ける。
//!
//! 本リポジトリでは `main.zig` のヘルプテキストがこの形で書かれている。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/20_multiline_strings.zig`

const std = @import("std");

// `cljw -h` で出るのと同じ形のヘルプ文字列
const HELP =
    \\Usage: cljw [options] [<file.clj> | -]
    \\  -e, --eval <expr>  Read, analyse, evaluate <expr>; print each result.
    \\  <file.clj>         Read+evaluate the named source file.
    \\  -                  Read+evaluate from stdin (heredoc-friendly).
    \\  -h, --help         Show this help.
    \\
;

pub fn main() !void {
    std.debug.print("[20] HELP length        : {d}\n", .{HELP.len});
    std.debug.print("[20] HELP body:\n{s}", .{HELP});
    std.debug.print("[20] note               : エスケープなし — 内部の `\\n` は 2 文字のまま\n", .{});
}
