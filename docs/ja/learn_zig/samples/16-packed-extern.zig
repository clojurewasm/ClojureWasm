//! 16: `packed struct(uN)` / `extern struct` / `align(N)`
//!
//! 通常の `struct` はフィールド順とパディングをコンパイラに任せる。
//! レイアウトを明示したいときは:
//!   - `packed struct(uN)` — bit 単位で詰める。総ビット幅 = `uN`
//!   - `extern struct`     — C ABI と同じレイアウト規約
//!
//! 本リポジトリの `HeapHeader` は `extern struct`（GC が読むレイアウト
//! を固定するため）、`Flags` は `packed struct(u8)`（marked / frozen /
//! 予約 6 ビットを 1 バイトに詰める）。
//!
//! `var x: T align(N)` で変数のアラインメント要求を上書きできる。
//! NaN ボックスはポインタの下位 3 bit を捨てて再利用するので、対象
//! 変数を `align(8)` 以上に揃える必要がある。
//!
//! 注: `@intFromPtr` と `&` ポインタは第 17 章で詳説するが、`align`
//! の効果を観察する都合でここでも先に使う。
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/16-packed-extern.zig`

const std = @import("std");

/// bit 単位のフラグ集合。総ビット幅 = u8
const Flags = packed struct(u8) {
    marked: bool = false,
    frozen: bool = false,
    _pad: u6 = 0,
};

/// C ABI 互換の固定レイアウト。`runtime/value.zig` の `HeapHeader` と同じ形
const Header = extern struct {
    tag: u8,
    flags: Flags,
};

pub fn main() !void {
    var h: Header = .{ .tag = 3, .flags = .{ .marked = true } };

    std.debug.print("[16] @sizeOf(Flags)     : {d}\n", .{@sizeOf(Flags)});
    std.debug.print("[16] @sizeOf(Header)    : {d}\n", .{@sizeOf(Header)});
    std.debug.print("[16] @alignOf(Header)   : {d}\n", .{@alignOf(Header)});
    std.debug.print("[16] tag={d} marked={} frozen={}\n", .{ h.tag, h.flags.marked, h.flags.frozen });

    // packed struct のフィールドはふつうの代入で書き換えられる
    h.flags.frozen = true;
    std.debug.print("[16] after freeze       : marked={} frozen={}\n", .{
        h.flags.marked, h.flags.frozen,
    });

    // `align(8)` を要求して、ポインタの下位 3 ビットが必ず 0 になるようにする
    var aligned: u64 align(8) = 0xCAFEBABE;
    std.debug.print("[16] align(8) addr % 8  : {d}\n", .{@intFromPtr(&aligned) % 8});
}
