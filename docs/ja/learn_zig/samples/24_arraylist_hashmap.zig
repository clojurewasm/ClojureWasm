//! 24: `std.ArrayList(T)` / `std.StringHashMapUnmanaged(V)`
//!
//! Zig 0.16 のコレクションは「unmanaged」がデフォルト — 自分の中に
//! アロケータを保持せず、操作のたびに引数で受け取る。これにより
//! 複数のコレクションが同じアロケータを共有しても重複保持しない。
//! 初期化は `.empty`、終了時に `deinit(alloc)`、操作のたびに `alloc`
//! を渡す。
//!
//! 本リポジトリの実例:
//!   - `std.array_hash_map.String(*Keyword)` — `KeywordInterner.table`
//!     （挿入順保持。`StringArrayHashMapUnmanaged` の deprecated 別名）
//!   - `std.StringHashMapUnmanaged(*Var)`             — `Namespace.vars`
//!   - `std.AutoHashMapUnmanaged(*const Var, Value)` — `BindingFrame.bindings`
//!
//! 実行方法: `zig run docs/ja/learn_zig/samples/24_arraylist_hashmap.zig`

const std = @import("std");

pub fn main() !void {
    // ArenaAllocator をバッキングに使えば、コレクション内部の確保も
    // 一括解放される（個別の `deinit(alloc)` は呼ぶが no-op になる）
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // ArrayList(i32) — `.empty` で初期化、操作のたびに `alloc` を渡す
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(alloc);

    try list.append(alloc, 10);
    try list.append(alloc, 20);
    try list.append(alloc, 30);

    // `pop()` は `?T` を返す（空なら null）
    const last = list.pop();
    std.debug.print("[24] popped             : {?d}\n", .{last});
    std.debug.print("[24] list len/items     : {d} / {any}\n", .{ list.items.len, list.items });

    // StringHashMapUnmanaged(u32) — 同じ「unmanaged」パターン
    var map: std.StringHashMapUnmanaged(u32) = .empty;
    defer map.deinit(alloc);

    try map.put(alloc, "alpha", 1);
    try map.put(alloc, "beta", 2);
    try map.put(alloc, "gamma", 3);

    std.debug.print("[24] map.count          : {d}\n", .{map.count()});
    if (map.get("beta")) |v| std.debug.print("[24] map.get(beta)      : {d}\n", .{v});

    // iterator で全エントリを巡回。`e.key_ptr.*` / `e.value_ptr.*` が
    // 実際のキー・値（ハッシュ表が rehash する都合で参照型を返す）
    var it = map.iterator();
    while (it.next()) |e| {
        std.debug.print("[24]   {s} -> {d}\n", .{ e.key_ptr.*, e.value_ptr.* });
    }
}
