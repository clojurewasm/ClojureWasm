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

`:foo` は同じ keyword であれば **どこに書かれても 1 個のヒープ
オブジェクトを共有します**。これを **interning** と呼びます。intern
されていれば `(= :foo :foo)` の判定は **`u64` の bit 比較 1 命令**
で済みます。

本章では、Phase 1 段階の `KeywordInterner`（**単一スレッド前提・
ロックなし**）を作ります。要点は **`Keyword` cell の memory layout
をここで凍結しておくこと** です。Phase 2.2 で rt-aware（mutex 付き）
に昇格しますが、cell layout は変わりません。既存テストを壊さず、
intern table の見え方だけが進化します。

「Phase 2.2 への伏線を Phase 1 から張る」。これが原則 P2（final
shape on day 1）の実践です。

---

## この章で学ぶこと

- なぜ keyword を **intern** するのか — `(identical? :foo :foo)` を
  pointer 比較で済ませる
- `Keyword` cell の memory layout (`header + ns + name + hash_cache`)
  と Phase 2.2 でも変わらない理由
- intern logic の流れ: 既存検索 → 当たれば返す / 外れたら新規 alloc
  + table 登録
- なぜ自前 `array_hash_map.String`（旧 `StringArrayHashMapUnmanaged`、
  Zig 0.16 で改名）を使い、`std.HashMap` のデフォルトを直に使わないのか
- Phase 1 の **「mutex 抜き」stub** が Phase 2.2 でどう **call site
  だけ** の変更で rt-aware に進化するか

---

## 1. なぜ keyword を intern するのか

### 等価判定を u64 bit 比較に潰したい

`:foo` を 100 箇所で書いたとします。intern していなければ、それぞれ
が独立した heap セルになります:

```
(:foo (key 1) :foo (key 2))    ;; 別オブジェクト 2 個
```

そして `=` で比較するたびに **string 比較** が必要になります
（`memcmp` が走る）。

intern していれば:

```
(:foo (slot 1, ptr 0xABC) :foo (slot 2, ptr 0xABC))   ;; 同じ pointer
```

→ `=` は **`u64` bit 比較** 1 命令（`a == b`）で済みます。
**HashMap のキーとして頻出する** keyword では、この差が積み上がって
いきます。

### Clojure の `(identical? a b)` 意味論

```clojure
(identical? :foo :foo)   ;; → true   (intern されてるので同じ obj)
(identical? "abc" "abc") ;; → false  (string は intern しない)
```

ClojureWasm v2 では keyword を intern します。symbol も intern する
予定ですが、それは Phase 2（`runtime/symbol.zig`）の話です。Phase 1
では keyword を先に扱います。

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

| フィールド   | サイズ  | 役割                                                               |
|--------------|---------|--------------------------------------------------------------------|
| `header`     | 2 byte  | `HeapHeader` (`tag` + `flags` + reserved)、Phase 5 mark bit を持つ |
| `_pad`       | 6 byte  | 8-byte alignment 確保                                              |
| `ns`         | 16 byte | `?[]const u8` — `:ns/name` の前半。bare keyword は `null`         |
| `name`       | 16 byte | `[]const u8` — keyword name 本体                                  |
| `hash_cache` | 4 byte  | precomputed Murmur3 hash                                           |

総計 ~44 byte（alignment 込みで 48 程度）。`hash_cache` を
**precompute** しているのは、HashMap の bucket 計算で keyword の
hash を何度も取り直すことになるためです。

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

**`Keyword` cell の field は 1 つも変わっていません**。NaN-boxed
encoding（pointer の bit pattern）も変わらないので、**既存の
`Value.encodeHeapPtr(.keyword, ...)` がそのまま動きます**。

これが「cell layout を Phase 1 で凍結しておく」ことの威力です。

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

のように **stack 上の一時バッファ** を渡してくる可能性があります。
intern table はプロセス寿命なので、**自分で copy を取らないと
dangling pointer になってしまいます**。`alloc.dupe(u8, name)` で
深いコピーを取るのが正解です。

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

- 既存ヒット時に `key` を free しないとリークします（table は新規
  パスで自分が key を保管するため、ヒット時の一時 key は呼び出し
  側で解放する必要がある）。
- `errdefer` を入れる代替案もありますが、Phase 1 stub では既存
  テストが通る最小限の実装で十分です。

</details>

---

## 4. なぜ自前 `array_hash_map.String`？

```zig
table: std.array_hash_map.String(*Keyword) = .empty,
```

なぜ `std.HashMap(...)` の汎用版でなく **`array_hash_map.String`** ？

> Zig 0.16 で旧 `std.StringArrayHashMapUnmanaged` は
> `std.array_hash_map.String` への deprecated 別名になりました
> （`zig build lint` の `no_deprecated` で検出される）。本書とソース
> はすべて新名に統一してあります — 「文字列キー版 array hash map」
> という意味は変わりません。

### 4 つの理由

1. **string key 向けに最適化された hash function** が用意されており、
   内部で string-aware な関数が使われます。
2. **`Unmanaged`** は allocator field を内部に持ちません。allocator
   は呼び出しのたびに渡します。これにより `KeywordInterner` 全体が
   `alloc` field 1 個で完結し、所有権が明示的になります。
3. **`ArrayHashMap`**（linear probing）は pointer-stability を保証
   しない代わりに **挿入順を保ちます**。デバッグ時に keyword の
   出現順を見たいケースで便利です。
4. **小さなテーブルで高速** に動作します。keyword は通常 100〜10000
   個のオーダーで、ArrayHashMap の linear probe はその規模で
   cache-friendly に振る舞います。

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
    table: std.array_hash_map.String(*Keyword) = .empty,

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

Phase 2.2（`07d5c34`）は cell を変えずに、API surface だけを進化
させたコミットです。差分の本質は次の通りです:

| Phase 1 (`b60924b`)         | Phase 2.2 (`07d5c34`)                                   |
|-----------------------------|---------------------------------------------------------|
| `interner.intern(ns, name)` | `intern(rt, ns, name)` (top-level fn)                   |
| ロックなし                  | `rt.io` 経由で `std.Io.Mutex.lockUncancelable` を取る   |
| owner = `*KeywordInterner`  | owner = `*Runtime`, `Runtime.keywords: KeywordInterner` |
| API method 1 個             | `internUnlocked` (旧名) + 新たな `intern(rt, ...)`      |

**low-level メソッド**（`internUnlocked` / `findUnlocked`）を
**残した** のが要所です。テストや fixed-input bootstrap（single-
thread が保証されている経路）からは旧 API を使い続けられます。
`asKeyword`（pure pointer 算術なのでロック不要）も変更していません。

ROADMAP **§A7（Concurrency and errors are designed in on day 1）**
が、コードから読み取れる形で実装されています。

---

## 6. 設計判断と却下した代替

| 案                                             | 採否 | 理由                                                                    |
|------------------------------------------------|------|-------------------------------------------------------------------------|
| **heap-allocated cell + 自前 hash table**      | ✓   | cell address を Value に encode してエクイティ判定が pointer 比較で済む |
| Java enum の真似                               | ✗   | Zig には JVM の class loader / static field 機構がない                  |
| `[]const u8` を直接 Value に                   | ✗   | Value は 8 byte、slice は 16 byte で収まらない                          |
| `std.HashMap(string, *Keyword)`                | ✗   | `array_hash_map.String` の方が小規模 + cache-friendly                   |
| Phase 1 から `std.Io.Mutex` を入れる           | ✗   | single-thread Phase 1 で overhead 無駄、cell layout だけ凍結すれば十分  |
| keyword cell に `ns_len + name_len` を持たせる | ✗   | `[]const u8` の長さで判る、redundant                                    |
| Phase 2 で cell layout を変える                | ✗   | 既存テスト破壊、NaN encoding 周りも触らねばならない                     |

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

| 軸                | v1 (`~/Documents/MyProducts/ClojureWasm`)        | v1_ref                                | Clojure JVM                                | 本リポ                                              |
|-------------------|--------------------------------------------------|---------------------------------------|--------------------------------------------|-----------------------------------------------------|
| API ownership     | `keyword_intern.zig` 82 行、`pub var` グローバル | `keyword.zig` 308 行、`*Runtime` 渡し | `Keyword.intern(Symbol)` static method     | Phase 1: `*KeywordInterner` / Phase 2.2: `*Runtime` |
| ロック            | なし (single-thread 前提)                        | `std.Io.Mutex`                        | `static ConcurrentHashMap`                 | Phase 1: なし / Phase 2.2: `std.Io.Mutex`           |
| cell layout       | 後付け (Phase 後半に固定化)                      | Day 1 凍結                            | `Symbol` referent + `name`/`ns` (`String`) | Day 1 凍結                                          |
| hash precompute   | あり (i32)                                       | あり (u32)                            | あり (`int _hasheq`)                       | あり (u32)                                          |
| qualified keyword | sentinel `"/"` で string 連結                    | composite key                         | `Symbol` 内蔵の ns/name                    | composite key                                       |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は **`pub var` でグローバル table** を持っていました。ROADMAP
  §13 で「`pub var` 禁止」が立ったあと、本リポジトリは構造体 owner
  に切り替えています。
- Clojure JVM の `static ConcurrentHashMap` は process-wide
  singleton です。本リポジトリでは **`Runtime` 単位の table** に
  したので、複数 Runtime を独立に動かせます（test fixture でも
  実証済み）。
- Phase 1 で **mutex を仕込んでいない**：v1_ref は最初から mutex
  入りで、single-thread Phase 1 のテスト時間が長くなりました。本
  リポジトリは「cell layout だけ凍結、ロックは Phase 2.2 で入れる」
  という段階分けにしています。

---

## 9. Feynman 課題

1. なぜ `:foo` を intern するのか。6 歳の自分に向けて 1 行で。
2. cell layout を Phase 1 で凍結することの利点は何か。1 行で。
3. Phase 2.2 で `internUnlocked`（旧名）を **残した** 理由は何か。
   1 行で。

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

第 7 章: [Form AST と Tokenizer](./0007_form_and_tokenizer.md)

— ここからついに **Clojure source text** に踏み込みます。`(+ 1 2)`
という string が `Form` の tagged union にどう構造化されるか、
tokenizer が **`SourceLocation` を各 token にどう付与する** のかを
見ていきます。
