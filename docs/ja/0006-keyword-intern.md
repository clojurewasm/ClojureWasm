---
chapter: 6
commits:
  - b60924b
related-tasks:
  - §9.3 / 1.6
related-chapters:
  - 0005
  - 0007
date: 2026-04-27
---

# 0006 — Keyword interning — 安定した cell layout

> 対応 task: §9.3 / 1.6 / 所要時間: 60〜80 分

`:foo` は同じ keyword なら **どこに書かれても 1 個のヒープオブジェ
クト**を共有する。これを **interning** という。intern していれば
`(= :foo :foo)` の判定は **`u64` の bit 比較 1 命令** で済む。

本章では、Phase 1 段階の `KeywordInterner`（**単一スレッド前提・
ロックなし**）を作る。要点は **`Keyword` cell の memory layout を
ここで凍結**しておくこと。Phase 2.2 で rt-aware (mutex 付き) に
昇格するが、cell layout は変わらない — 既存テストは破壊されず、
intern table の見え方だけが進化する。

「Phase 2.2 への伏線を Phase 1 から張る」、これが原則 P2 (final
shape on day 1) の実践。

---

## この章で学ぶこと

- なぜ keyword を **intern** するのか — `(identical? :foo :foo)` を
  pointer 比較で済ませる
- `Keyword` cell の memory layout (`header + ns + name + hash_cache`)
  と Phase 2.2 でも変わらない理由
- intern logic の流れ: 既存検索 → 当たれば返す / 外れたら新規 alloc
  + table 登録
- なぜ自前 `StringArrayHashMapUnmanaged` を使い、`std.HashMap` の
  デフォルトを直に使わないのか
- Phase 1 の **「mutex 抜き」stub** が Phase 2.2 でどう **call site
  だけ** の変更で rt-aware に進化するか

---

## 1. なぜ keyword を intern するのか

### 等価判定を u64 bit 比較に潰したい

`:foo` を 100 箇所で書いたとする。intern していなければ、それぞれが
独立した heap セルになる:

```
(:foo (key 1) :foo (key 2))    ;; 別オブジェクト 2 個
```

そして `=` で比較するたびに **string 比較** が必要 (`memcmp` が走る)。

intern していれば:

```
(:foo (slot 1, ptr 0xABC) :foo (slot 2, ptr 0xABC))   ;; 同じ pointer
```

→ `=` は **`u64` bit 比較** 1 命令 (`a == b`) で済む。
**HashMap のキーとして頻出**する keyword でこの差は積み上がる。

### Clojure の `(identical? a b)` 意味論

```clojure
(identical? :foo :foo)   ;; → true   (intern されてるので同じ obj)
(identical? "abc" "abc") ;; → false  (string は intern しない)
```

ClojureWasm v2 は keyword だけ intern。symbol も intern するが、
それは Phase 2 (`runtime/symbol.zig`)。Phase 1 では keyword が先。

### 演習 6.1: intern の効果を予測 (L1 — 予測検証)

以下のテストの `expectEqual(...)` が **何を比較しているか** に注目:

```zig
test "intern returns the same pointer for repeats" {
    var interner = KeywordInterner.init(testing.allocator);
    defer interner.deinit();

    const a = try interner.intern(null, "bar");
    const b = try interner.intern(null, "bar");

    try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));   // ← Q
}
```

Q1: `@intFromEnum(a)` は何を取り出している？
Q2: `a == b` の代わりに `@intFromEnum(a) == @intFromEnum(b)` を書いた
  理由は？
Q3: 仮に intern せず毎回 `alloc.create(Keyword)` した場合、この
  テストは pass する？ fail する？

<details>
<summary>答え</summary>

**Q1**: `Value` は `enum(u64) { ..., _ }` で、`@intFromEnum` は
裸の `u64` を取り出す（`Value` は non-exhaustive enum なので任意の
`u64` を表現できる）。これは結局 **NaN-boxed の bit pattern** —
heap pointer の場合、shifted address が下位 45 bit に入っている。

**Q2**: Zig の `Value` は `enum(u64)`。non-exhaustive enum 同士の
`==` は **コンパイル可能だが直感に反する**ので、`@intFromEnum` で
明示的に `u64` に落としてから比較する慣習。

**Q3**: **fail**。intern しなければ毎回別の heap address が割り
当てられる。`@intFromEnum(a)` (= shifted address) も違う値になる。

</details>

---

## 2. `Keyword` cell layout — Phase 2.2 でも凍結

```zig
//! Phase 1 stub (commit b60924b)
pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    /// Null for unqualified keywords like `:foo`.
    ns: ?[]const u8,
    name: []const u8,
    /// Precomputed Murmur3 hash of `ns/name` (or just `name`).
    hash_cache: u32,

    pub fn formatQualified(self: *const Keyword, buf: []u8) []const u8 {
        // ...
    }
};
```

### フィールド役割

| フィールド | サイズ | 役割 |
|------|------|------|
| `header` | 2 byte | `HeapHeader` (`tag` + `flags` + reserved)、Phase 5 mark bit を持つ |
| `_pad` | 6 byte | 8-byte alignment 確保 |
| `ns` | 16 byte | `?[]const u8` — `:ns/name` の前半。bare keyword は `null` |
| `name` | 16 byte | `[]const u8` — keyword name 本体 |
| `hash_cache` | 4 byte | precomputed Murmur3 hash |

総計 ~44 byte (alignment 込みで 48 程度)。`hash_cache` を
**precompute** しているのは、HashMap の bucket 計算で keyword を
頻繁に hash しなおすため。

### 4 つの設計原則を満たす

1. **identity 比較**: heap pointer が `Value` に encode されるので、
   pointer 比較 = `Value` 比較。
2. **構造化される識別子**: `ns / name` の 2 段で qualified keyword
   `:foo/bar` をサポート。
3. **hash の amortized cost**: 1 回計算して `hash_cache` に保存、
   その後の HashMap 操作で reuse。
4. **alignment 固定**: 8-byte aligned cell が NaN-boxed encoding
   の前提 (`addr >> 3` で 45 bit 化、第 0002 章参照)。

### Phase 2.2 で何が変わるか — cell layout は **変わらない**

`b60924b` 時点 (Phase 1) のコメント:

```
//! ### Phase-1 scope
//!
//! This is a self-contained `KeywordInterner` that owns its allocator
//! and table. Phase 2.0 widens the public API to take a `*Runtime` and
//! wraps the table with `std.Io.Mutex.lockUncancelable(rt.io)`. Pinning
//! the *struct shape* now (header + ns + name + hash_cache) means
//! Phase 2.0 only changes call sites, not memory layout.
```

Phase 2.2 (`07d5c34`) で実際に変わったもの:

- `KeywordInterner` に `mutex: std.Io.Mutex = .init` フィールドを追加
- 既存メソッドを `internUnlocked` / `findUnlocked` にリネーム
- 新たな top-level 関数 `intern(rt, ns, name)` / `find(rt, ns, name)`
  を追加（rt.io 経由で lock/unlock）

**`Keyword` cell の field は 1 つも変わっていない**。NaN-boxed
encoding（pointer の bit pattern）も変わらない → **既存の
`Value.encodeHeapPtr(.keyword, ...)` がそのまま動く**。

これが「cell layout を Phase 1 で凍結」の威力。

---

## 3. intern logic の流れ

```zig
pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value {
    const key = try formatKey(self.alloc, ns, name);

    if (self.table.get(key)) |existing| {
        self.alloc.free(key);
        return Value.encodeHeapPtr(.keyword, existing);
    }

    const kw = try self.alloc.create(Keyword);
    kw.* = .{
        .header = HeapHeader.init(.keyword),
        .ns = if (ns) |n| (try self.alloc.dupe(u8, n)) else null,
        .name = try self.alloc.dupe(u8, name),
        .hash_cache = computeHash(ns, name),
    };

    try self.table.put(self.alloc, key, kw);
    return Value.encodeHeapPtr(.keyword, kw);
}
```

ステップ:

1. **`formatKey(ns, name)`** — `:foo/bar` は `"foo/bar"`、`:foo` は
   `"foo"` という composite key を作る。table のキーとして使う
   一時 string。
2. **`table.get(key)`** — 既存の `*Keyword` が見つかれば、
   - 一時 key を free（自分で alloc したので責任持つ）
   - 既存 cell の Value encoding を返す
3. **見つからなければ** —
   - `alloc.create(Keyword)` で新セル
   - ns / name を `dupe` (caller の slice はテンポラリかもしれない)
   - `computeHash` で hash precompute
   - `table.put(key, kw)` で **table が key を所有**する
4. encoded Value を返す

### `dupe` する理由

caller が:

```zig
var name_buf: [16]u8 = undefined;
const name = std.fmt.bufPrint(&name_buf, "kw_{d}", .{i}) catch unreachable;
_ = try interner.intern(null, name);
```

のように **stack 上の一時バッファ** を渡してくる可能性がある。
intern table はプロセス寿命なので、**自分で copy を取らないと
dangling pointer** になる。`alloc.dupe(u8, name)` で深いコピーを取る
のが正解。

### 演習 6.2: intern 関数本体を再構成 (L2 — 部分再構成)

シグネチャだけ与える:

```zig
pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value {
    // ここから書く
    // 仕様:
    // 1. (ns, name) 既出なら、既存の Value を返す（一時 key を free）
    // 2. 既出でなければ、新しい Keyword を heap alloc して登録、
    //    encoded Value を返す
    // 3. ns/name の slice は dupe して保存（caller の memory に依存しない）
}
```

ヒント:

- `formatKey(self.alloc, ns, name)` で一時 key を作る
- `self.table.get(key)` で既存判定
- 既存なら `self.alloc.free(key)` してから encode して返す
- 新規なら `self.alloc.create(Keyword)` + `dupe` で構築
- `self.table.put(self.alloc, key, kw)` で登録 (key の所有権は table)
- 戻り値は `Value.encodeHeapPtr(.keyword, kw)`

<details>
<summary>答え</summary>

```zig
pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value {
    const key = try formatKey(self.alloc, ns, name);

    if (self.table.get(key)) |existing| {
        self.alloc.free(key);
        return Value.encodeHeapPtr(.keyword, existing);
    }

    const kw = try self.alloc.create(Keyword);
    kw.* = .{
        .header = HeapHeader.init(.keyword),
        .ns = if (ns) |n| (try self.alloc.dupe(u8, n)) else null,
        .name = try self.alloc.dupe(u8, name),
        .hash_cache = computeHash(ns, name),
    };

    try self.table.put(self.alloc, key, kw);
    return Value.encodeHeapPtr(.keyword, kw);
}
```

注意点:

- 既存ヒット時に `key` を free しないとリークする (table は key を
  自分で持っていて、新規パスで保管する)
- `errdefer` を入れる代替案もあるが、Phase 1 stub では既存テストが
  通る最小限の実装で OK

</details>

---

## 4. なぜ自前 `StringArrayHashMapUnmanaged`？

```zig
table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,
```

なぜ `std.HashMap(...)` の汎用版でなく **`StringArrayHashMapUnmanaged`** ？

### 4 つの理由

1. **string key 用に最適化された hash function** — 内部で string-aware
   な関数を使う。
2. **`Unmanaged`** — allocator field を内部に持たない。allocator は
   呼び出し時に毎回渡す。これにより `KeywordInterner` 全体が `alloc`
   field 1 個で完結し、ownership が明示的。
3. **`ArrayHashMap`** (linear probing) — pointer-stability の保証は
   ない代わりに **insertion order を保つ**。デバッグ時に keyword の
   出現順を見たいときに便利。
4. **小さなテーブルで高速** — keyword は通常 100〜10000 個オーダー。
   ArrayHashMap の linear probe は cache-friendly。

### 演習 6.3: KeywordInterner module 全体を再構成 (L3)

ファイル名と公開 API のみ:

- File: `src/runtime/keyword.zig` (Phase 1 stub @ b60924b)
- 公開 API:
  - `pub const Keyword = struct { header, ns, name, hash_cache, pub fn formatQualified };`
  - `pub const KeywordInterner = struct { alloc, table, pub fn init/deinit/intern/find };`
  - `pub fn asKeyword(val: Value) *const Keyword`
- 内部 helpers:
  - `fn formatKey(alloc, ns, name) ![]u8` — `"ns/name"` or `"name"`
  - `fn computeHash(ns, name) u32` — `ns` がある時は
    `hash.hashString(ns) *% 31 +% hash.hashString("/") *% 31 +% hash.hashString(name)`、
    なければ `hash.hashString(name)`

<details>
<summary>答え骨子</summary>

```zig
//! Keyword interning — Phase-1 single-threaded stub.

const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;
const HeapHeader = value.HeapHeader;
const HeapTag = value.HeapTag;
const hash = @import("hash.zig");

pub const Keyword = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    ns: ?[]const u8,
    name: []const u8,
    hash_cache: u32,

    pub fn formatQualified(self: *const Keyword, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, ":{s}{s}{s}", .{
            if (self.ns) |n| n else "",
            if (self.ns != null) "/" else "",
            self.name,
        }) catch buf[0..@min(buf.len, 1)];
    }
};

pub const KeywordInterner = struct {
    alloc: std.mem.Allocator,
    table: std.StringArrayHashMapUnmanaged(*Keyword) = .empty,

    pub fn init(alloc: std.mem.Allocator) KeywordInterner {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *KeywordInterner) void {
        for (self.table.keys(), self.table.values()) |key, kw| {
            if (kw.ns) |n| self.alloc.free(n);
            self.alloc.free(kw.name);
            self.alloc.destroy(kw);
            self.alloc.free(key);
        }
        self.table.deinit(self.alloc);
        self.table = .empty;
    }

    pub fn intern(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) !Value {
        const key = try formatKey(self.alloc, ns, name);
        if (self.table.get(key)) |existing| {
            self.alloc.free(key);
            return Value.encodeHeapPtr(.keyword, existing);
        }
        const kw = try self.alloc.create(Keyword);
        kw.* = .{
            .header = HeapHeader.init(.keyword),
            .ns = if (ns) |n| (try self.alloc.dupe(u8, n)) else null,
            .name = try self.alloc.dupe(u8, name),
            .hash_cache = computeHash(ns, name),
        };
        try self.table.put(self.alloc, key, kw);
        return Value.encodeHeapPtr(.keyword, kw);
    }

    pub fn find(self: *KeywordInterner, ns: ?[]const u8, name: []const u8) ?Value {
        const key = formatKey(self.alloc, ns, name) catch return null;
        defer self.alloc.free(key);
        if (self.table.get(key)) |kw| {
            return Value.encodeHeapPtr(.keyword, kw);
        }
        return null;
    }
};

pub fn asKeyword(val: Value) *const Keyword {
    std.debug.assert(val.tag() == .keyword);
    return val.decodePtr(*const Keyword);
}

fn formatKey(alloc: std.mem.Allocator, ns: ?[]const u8, name: []const u8) ![]u8 {
    if (ns) |n| {
        const key = try alloc.alloc(u8, n.len + 1 + name.len);
        @memcpy(key[0..n.len], n);
        key[n.len] = '/';
        @memcpy(key[n.len + 1 ..], name);
        return key;
    }
    return try alloc.dupe(u8, name);
}

fn computeHash(ns: ?[]const u8, name: []const u8) u32 {
    if (ns) |n| {
        var h: u32 = hash.hashString(n);
        h = h *% 31 +% hash.hashString("/");
        h = h *% 31 +% hash.hashString(name);
        return h;
    }
    return hash.hashString(name);
}
```

検証: `bash test/run_all.sh` で keyword.zig の 7 ケース (`intern
creates a keyword Value` / `intern returns the same pointer for
repeats` / `qualified keywords are distinct from bare` / etc.) が
緑。

</details>

---

## 5. Phase 2.2 への伏線

Phase 2.2 (`07d5c34`) は cell を変えずに、API surface だけを進化
させた。差分の本質は:

| Phase 1 (`b60924b`) | Phase 2.2 (`07d5c34`) |
|------|------|
| `interner.intern(ns, name)` | `intern(rt, ns, name)` (top-level fn) |
| ロックなし | `rt.io` 経由で `std.Io.Mutex.lockUncancelable` を取る |
| owner = `*KeywordInterner` | owner = `*Runtime`, `Runtime.keywords: KeywordInterner` |
| API method 1 個 | `internUnlocked` (旧名) + 新たな `intern(rt, ...)` |

**low-level メソッド** (`internUnlocked` / `findUnlocked`) を
**残した** のがミソ。テストや fixed-input bootstrap (single-thread
が保証されている path) からは旧 API を使い続けられる。`asKeyword`
（pure pointer 算術なので lock 不要）も変えていない。

ROADMAP **§A7 (Concurrency and errors are designed in on day 1)** が
読める形で実装される。

---

## 6. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| **heap-allocated cell + 自前 hash table** | ✓ | cell address を Value に encode してエクイティ判定が pointer 比較で済む |
| Java enum の真似 | ✗ | Zig には JVM の class loader / static field 機構がない |
| `[]const u8` を直接 Value に | ✗ | Value は 8 byte、slice は 16 byte で収まらない |
| `std.HashMap(string, *Keyword)` | ✗ | `StringArrayHashMapUnmanaged` の方が小規模 + cache-friendly |
| Phase 1 から `std.Io.Mutex` を入れる | ✗ | single-thread Phase 1 で overhead 無駄、cell layout だけ凍結すれば十分 |
| keyword cell に `ns_len + name_len` を持たせる | ✗ | `[]const u8` の長さで判る、redundant |
| Phase 2 で cell layout を変える | ✗ | 既存テスト破壊、NaN encoding 周りも触らねばならない |

ROADMAP §4.2 (NaN-boxed Value) / §A7 (concurrency designed in on
day 1) / P2 (final shape on day 1) と整合。

---

## 7. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout b60924b
zig build test
# keyword.zig の test 群が緑（Phase 1 stub の 7 ケース）

git checkout 07d5c34
zig build test
# Phase 2.2 後でも cell layout は変わらず、追加 test (rt-aware) も緑

git checkout cw-from-scratch
```

intern の identity を **目で見る**:

```zig
const a = try interner.intern(null, "shared");
const b = try interner.intern(null, "shared");
std.debug.print("a = 0x{X:0>16}\n", .{@intFromEnum(a)});
std.debug.print("b = 0x{X:0>16}\n", .{@intFromEnum(b)});
// → 同じ bit pattern (intern が機能している)

const c = try interner.intern("ns", "shared");
std.debug.print("c = 0x{X:0>16}\n", .{@intFromEnum(c)});
// → 別の bit pattern (qualified なので別 cell)
```

---

## 8. 教科書との対比

| 軸 | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM | 本リポ |
|----|------|------|------|------|
| API ownership | `keyword_intern.zig` 82 行、`pub var` グローバル | `keyword.zig` 308 行、`*Runtime` 渡し | `Keyword.intern(Symbol)` static method | Phase 1: `*KeywordInterner` / Phase 2.2: `*Runtime` |
| ロック | なし (single-thread 前提) | `std.Io.Mutex` | `static ConcurrentHashMap` | Phase 1: なし / Phase 2.2: `std.Io.Mutex` |
| cell layout | 後付け (Phase 後半に固定化) | Day 1 凍結 | `Symbol` referent + `name`/`ns` (`String`) | Day 1 凍結 |
| hash precompute | あり (i32) | あり (u32) | あり (`int _hasheq`) | あり (u32) |
| qualified keyword | sentinel `"/"` で string 連結 | composite key | `Symbol` 内蔵の ns/name | composite key |

引っ張られず本リポの理念で整理した点：

- v1 は **`pub var` でグローバル table** を持っていた → ROADMAP §13
  で「`pub var` 禁止」が立った後、本リポは構造体 owner にする。
- Clojure JVM の `static ConcurrentHashMap` は process-wide singleton。
  本リポは **`Runtime` 単位の table** にしたので、複数 Runtime が
  独立して動かせる（test fixture で実証）。
- Phase 1 で **mutex を仕込まない**: v1_ref は最初から mutex 入りで、
  single-thread Phase 1 のテスト時間が長くなった。本リポは
  「cell layout だけ凍結、ロックは Phase 2.2 で入れる」段階分け。

---

## 9. Feynman 課題

1. なぜ `:foo` を intern するのか？ 6 歳の自分に 1 行で。
2. cell layout を Phase 1 で凍結することの利点は？ 1 行で。
3. Phase 2.2 で `internUnlocked` (旧名) を **残した** 理由は？ 1 行で。

---

## 10. チェックリスト

- [ ] 演習 6.1: intern が pointer 比較を可能にする仕組みを 3 問
      予測検証できる
- [ ] 演習 6.2: `intern` 関数本体をシグネチャだけから書ける
- [ ] 演習 6.3: `keyword.zig` 全体を公開 API リストだけから書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] Phase 2.2 で何が変わって何が変わっていないか 1 文で言える
- [ ] ROADMAP §A7 / §4.2 / §P2 を即座に指せる

---

## 次へ

第 7 章: [Form AST と Tokenizer](./0007-form-and-tokenizer.md)

— ここからついに **Clojure source text** に踏み込む。`(+ 1 2)`
という string が `Form` の tagged union にどう構造化されるか、
そして tokenizer がどう **`SourceLocation` を毎 token に付ける**
のか、を見ます。
