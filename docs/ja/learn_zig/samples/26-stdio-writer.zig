//! 26: `std.Io.Writer` と Juicy Main
//!
//! Zig 0.16 で `std.io` → `std.Io` に大移動した。書き込み API は
//! 型消去された `*std.Io.Writer` 一本に統合されている。
//!
//! 構築の流れ:
//!     std.Io.File.stdout()        → std.Io.File を取得
//!         .writer(io, &buf)       → バッファ付き writer
//!         .interface              → 型消去された *Writer
//!
//! `flush()` を忘れると、バッファが file に届かないまま終わる。
//!
//! `pub fn main(init: std.process.Init)`（"Juicy Main"）のシグネチャを
//! 使うと、`init.io` (`std.Io`)、`init.gpa` (汎用アロケータ)、
//! `init.arena` (プロセス寿命の arena)、`init.minimal.args` (引数
//! イテレータ) が一括で受け取れる。本リポジトリの `src/main.zig` が
//! まさにこの形を採用している。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/26-stdio-writer.zig`

const std = @import("std");
const Writer = std.Io.Writer;

// 引数を `*Writer` で受ければ、stdout でもメモリでも何でも書ける
fn writeReport(w: *Writer, label: []const u8, value: i32) Writer.Error!void {
    try w.print("[26] {s:<12} = {d}\n", .{ label, value });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // stdout への書き込みは「File → writer(io, buf) → interface」の 3 段
    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    try stdout.writeAll("[26] hello via std.Io.Writer\n");
    try writeReport(stdout, "alpha", 100);
    try writeReport(stdout, "beta", 200);
    try writeReport(stdout, "gamma", 300);

    // `.fixed(&buf)` は固定バッファに書き出す Writer。アロケータも flush も不要で、
    // テスト用の出力捕捉に便利
    var scratch: [64]u8 = undefined;
    var w: Writer = .fixed(&scratch);
    try w.print("captured={d}", .{42});
    try stdout.print("[26] .fixed buffered    : {s}\n", .{w.buffered()});

    // `flush()` を忘れるとバッファが file に届かない
    try stdout.flush();
}
