//! 23: アロケータ — `std.mem.Allocator` / `ArenaAllocator`
//!
//! Zig には「グローバル `malloc`」が無い。すべての確保は明示的な
//! `std.mem.Allocator` 引数を取る関数経由で行う。本リポジトリで
//! 実際に登場するアロケータは:
//!   - `std.heap.ArenaAllocator` — フェーズ単位で一括解放
//!   - `std.heap.page_allocator` — OS ページを直接確保するシンプルな
//!     バッキング（本サンプルの ArenaAllocator のバッキングに使う）
//!   - `init.gpa` — `std.process.Init`（Juicy Main、第 26 章）から
//!     受け取るプロセス全体の汎用アロケータ
//!   - `std.testing.allocator` — テスト時のリーク検出器
//!
//! 主要 API:
//!   - `alloc.alloc(T, n)`    → `[]T` を確保
//!   - `alloc.create(T)`      → `*T` を 1 つ確保
//!   - `alloc.dupe(T, src)`   → スライスを複製
//!   - `alloc.free(slice)`    → スライス解放
//!   - `alloc.destroy(ptr)`   → 単一値解放
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/23-allocator.zig`

const std = @import("std");

const Cons = struct {
    head: i32,
    tail: ?*Cons,
};

pub fn main() !void {
    // バッキングは `std.heap.page_allocator`（本リポジトリで使われている
    // のと同じシンプルな選択肢）。ArenaAllocator はその上に「まとめて
    // 解放」を重ねる薄いラッパー
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // `alloc(T, n)` — `[]T` を確保。アリーナ系では個別 free 不要だが、
    // 慣習として書ける（no-op として動く）
    const buf = try alloc.alloc(u8, 8);
    var i: usize = 0;
    while (i < buf.len) : (i += 1) buf[i] = '*';
    std.debug.print("[23] alloc(u8, 8)       : {s}\n", .{buf});

    // `dupe(T, src)` — スライスを別アロケータ上に複製
    const owned = try alloc.dupe(u8, "hello");
    std.debug.print("[23] dupe               : {s}\n", .{owned});

    // `create(T)` — `*T` を 1 つ確保。本リポジトリの `Cons` などの
    // ヒープ確保はすべてこの形
    const c1 = try alloc.create(Cons);
    c1.* = .{ .head = 1, .tail = null };
    const c2 = try alloc.create(Cons);
    c2.* = .{ .head = 2, .tail = c1 };
    const c3 = try alloc.create(Cons);
    c3.* = .{ .head = 3, .tail = c2 };

    // optional ポインタを `while (opt) |v|` で渡り歩く
    var node: ?*Cons = c3;
    var sum: i32 = 0;
    while (node) |n| {
        sum += n.head;
        node = n.tail;
    }
    std.debug.print("[23] arena cons sum     : {d}\n", .{sum});
    std.debug.print("[23] arena は deinit で一括解放（個別 free 不要）\n", .{});
}
