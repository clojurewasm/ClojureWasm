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
- なぜ自前 `array_hash_map.String`（Zig 0.16 で
  `StringArrayHashMapUnmanaged` の deprecated 別名になりました）を
  使い、`std.HashMap` のデフォルトを直に使わないのか
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

### intern が成立しているとは何が等しいということか

`Value` は `enum(u64) { ..., _ }` の non-exhaustive enum なので、
裸の `u64` を `@intFromEnum(v)` で取り出せます。これは **NaN-boxed
の bit pattern** であり、heap pointer なら shifted address が下位
45 bit に入っています。同じ keyword を 2 回 `interner.intern(null,
"bar")` した結果 `a` と `b` を比べるとき、

```zig
try testing.expectEqual(@intFromEnum(a), @intFromEnum(b));
```

が成り立つのは、**両者が同じヒープアドレスを指している** からです。
intern していない実装では毎回別の `alloc.create(Keyword)` が走り、
別の bit pattern が返るため、このテストは fail します。直接 `a == b`
と書かず一度 `u64` に落とすのは、non-exhaustive enum 同士の `==`
が「コンパイルできてしまうが直感に反する」ため、**bit 比較である
ことを明示する慣習** です。

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

### 既存ヒット時の `free(key)` を忘れない

intern logic で見落としやすいのは、**既存ヒット時に `key` を free
するパス**です。新規パスでは `table.put(self.alloc, key, kw)` で
table が key の所有権を引き取りますが、ヒット時は table 側で別の
key（最初の登録時の dupe）を持っているため、今回作った一時 key は
完全に宙に浮きます。`self.alloc.free(key)` を入れ忘れると **intern
回数ぶんだけリーク** が積み重なります。

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

### `formatKey` と `computeHash` のかたち

`formatKey` は qualified / unqualified を 1 本の string に潰す関数
です。`:foo/bar` は `"foo/bar"`、`:foo` は `"foo"` を返します。
`computeHash` は keyword の `hash_cache` を埋めるための Murmur3
合成で、`ns` ありなら `name` / `"/"` / `ns` の 3 hash を `*% 31 +%`
で結合し、なしなら `hashString(name)` をそのまま返します:

```zig
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

`*% 31 +%` の合成則は第 0005 章の `hashOrdered` と同じ係数で、
順序依存の組み合わせを Java と bit 互換に保ちます。

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

## この章で学んだこと

- **Keyword の `=` を `u64` 1 命令に潰すための仕掛けが intern**。
  cell layout を Phase 1 で凍結してあるので、Phase 2.2 で mutex を
  足すときに既存の NaN-boxed encoding は 1 bit も触らずに済む。
- intern logic で外しやすいのは **既存ヒット時の `free(key)`** と
  **新規時の `dupe(name)`** の 2 点。前者を忘れるとリーク、後者を
  忘れると caller のスタックが消えた瞬間に dangling になる。

---

## 次へ

第 7 章: [Form AST と Tokenizer](./0007_form_and_tokenizer.md)

— ここからついに **Clojure source text** に踏み込みます。`(+ 1 2)`
という string が `Form` の tagged union にどう構造化されるか、
tokenizer が **`SourceLocation` を各 token にどう付与する** のかを
見ていきます。
