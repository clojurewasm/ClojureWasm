---
chapter: 5
commits:
  - 902e22d
  - 1825f24
related-tasks:
  - §9.3 / 1.4
  - §9.3 / 1.5
related-chapters:
  - 0004
  - 0006
date: 2026-04-27
---

# 0005 — PersistentList と Murmur3 hash

> 対応 task: §9.3 / 1.4 + 1.5 / 所要時間: 80〜100 分

ClojureWasm の **最初のヒープオブジェクト** が cons cell です。
`(cons 1 nil)` や `(list 1 2 3)` が動くには、**ヒープ上に cell を
確保し、Value として encode し、`first` / `rest` / `count` を引ける
ようにする** ところまで揃える必要があります。本章ではそこまでを
仕上げます。

合わせて **Murmur3 hash** も用意します。Clojure JVM と **bit 互換な
hash 値** を出すための算術は、Zig の wrapping 演算（`*%` / `+%`）で
1:1 に再現できます。これを揃えておけば、将来 HashMap / HashSet で
永続コレクションの hash として使えるようになります。

2 つのトピックを 1 章にまとめている理由は、list と hash が **「永続
コレクションの最小ピース 2 つ」** だからです。一緒に学んでおくと、
互いの必然性が見えやすくなります。

---

## この章で学ぶこと

- cons cell の **メモリレイアウト** (`HeapHeader + first + rest +
  meta + count`) と 8-byte alignment
- `count: u32` を **precompute** することで O(1) の `count` が
  得られ、structural sharing と両立する仕組み
- nil semantics: `(first nil)` / `(rest nil)` / `(count nil)` が
  エラーにならず `nil` / `0` を返す Clojure 慣習を Zig で表現する
- Murmur3 の 3 関数 (`mixK1` / `mixH1` / `fmix`) と、それらを **1:1 で
  Java から移植**する流儀
- `*%` (wrapping multiply) / `+%` (wrapping add) — Java の int overflow
  と bit 互換になる Zig 0.16 のシンタックス
- `mixCollHash` / `hashOrdered` / `hashUnordered` — collection 用の
  hash 結合方式

---

## 1. cons cell のメモリレイアウト

```zig
//! src/runtime/collection/list.zig 17-28 行
pub const Cons = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    first: Value,
    rest: Value,
    meta: Value,
    count: u32,

    comptime {
        std.debug.assert(@alignOf(Cons) >= 8);
    }
};
```

### フィールド役割

| フィールド | サイズ | 役割                                                                     |
|------------|--------|--------------------------------------------------------------------------|
| `header`   | 2 byte | `HeapHeader` (`tag` + `flags` + reserved)。GC mark bit が flags 内に入る |
| `_pad`     | 6 byte | 8-byte alignment 確保のための明示的 padding                              |
| `first`    | 8 byte | head の `Value` (NaN-boxed `u64`)                                        |
| `rest`     | 8 byte | tail。`nil` または別 cons cell の Value                                  |
| `meta`     | 8 byte | metadata map (`{:line 7 :col 3}` 等)、デフォルト `nil`                   |
| `count`    | 4 byte | リスト全体の長さ。precompute で O(1)                                     |

合計 36 byte（alignment 込みで 40）です。NaN-boxed encoding の都合
で **Value はすべて 8-byte aligned に置きたい** ため、cell 全体も
**8-byte alignment** を満たす必要があります。これを `comptime`
ブロックで `assert` しています。

### なぜ `_pad: [6]u8` を明示するか

- `HeapHeader` は 2 byte (`tag: u8 + flags: packed struct(u8)`)。
  これだけだと次の `first: Value` (8 byte) が 8-byte aligned に
  ならない (offset 2 だと alignment 違反)。
- Zig の struct は **デフォルトで extern struct でない限り、
  field 順とその間の padding** をコンパイラが好きに決める。
- 明示的に `[6]u8` を入れることで「自分で alignment を制御する」
  ことを宣言。
- HeapHeader (offset 0) → \_pad (offset 2..7) → first (offset 8) →
  rest (offset 16) → meta (offset 24) → count (offset 32) と、
  きれいに整列します。

### nil semantics と `tag()` 分岐

```zig
pub fn first(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).first,
        else => .nil_val,
    };
}

pub fn countOf(val: Value) u32 {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).count,
        else => 0,
    };
}
```

Clojure JVM:
```clojure
(first nil)        ; → nil
(rest nil)         ; → ()
(count nil)        ; → 0
(count "abc")      ; → 3 (string も counted)
```

「ぜろ」ではなく「nil 互換」というのが Clojure の哲学です。
**`(first nil)` で NPE は発生しません**。これを `else => .nil_val`
の **fallthrough** で表現します。

### 演習 5.1: nil semantics を予測 (L1 — 予測検証)

以下のコードの結果を予測してください:

```zig
const lst = try cons(alloc, Value.initInteger(1),
              try cons(alloc, Value.initInteger(2),
                try cons(alloc, Value.initInteger(3), .nil_val)));

const a = first(lst).asInteger();
const b = first(rest(lst)).asInteger();
const c = first(rest(rest(rest(lst))));    // ← ?
const d = countOf(.nil_val);                // ← ?
const e = countOf(Value.initInteger(42));   // ← ?
```

<details>
<summary>答え</summary>

| 変数 | 値              | 理由                                        |
|------|-----------------|---------------------------------------------|
| `a`  | `1`             | head                                        |
| `b`  | `2`             | rest の head                                |
| `c`  | `Value.nil_val` | rest を 3 回辿ると nil、`first(nil) = nil`  |
| `d`  | `0`             | nil の count は 0 (Clojure 互換)            |
| `e`  | `0`             | integer は list でないので fallthrough → 0 |

ポイント: `else => .nil_val` / `else => 0` の **fallthrough** が
あるおかげで、呼び出し側で **`val.tag() == .list` を毎回チェック
する必要がありません**。

</details>

---

## 2. `count: u32` を precompute する設計

```zig
pub fn cons(alloc: std.mem.Allocator, head: Value, tail: Value) !Value {
    const cell = try alloc.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),    // ← O(1) でわかる
    };
    return Value.encodeHeapPtr(.list, cell);
}
```

### 何が偉いか — structural sharing と count の対称性

```clj
(def xs (list 1 2 3))    ;; count = 3, cells: a → b → c → nil
(def ys (cons 0 xs))     ;; count = 4, cells: d → a → b → c → nil
                         ;;                         (a, b, c は xs と共有)
```

`d.count` を作るときは、**`xs.count` を読むだけで 1 + 3 = 4** が
求まります。リスト全体を traverse する必要はありません。これが
**structural sharing と precomputed count の対称性** です。

逆に「count を持たない」設計にすると：
- `(count xs)` は O(n) で list を辿らないと求められない
- `cons` 1 回で `count` を埋める設計を採るなら、O(1) precompute が
  必須

Clojure JVM の `PersistentList` も同様に `_count` field を持って
います。

### 空リストの sentinel

本実装では **空リストは `nil` で代用しています**（cons 0 個 = nil）。
別案として、`EMPTY` という特別な空リスト cell を用意する選択もあり、
Clojure JVM は `PersistentList.EMPTY` を持っています。

ClojureWasm v2 が nil で代用しているのには、次のような利点が
あります：

- nil semantics を統一できる (`(seq nil) = nil`、`(seq ())` も nil)
- ヒープに「空 cell」が 1 個だけ存在する状況を回避（GC 上の root 管理が
  単純）
- ROADMAP §4.2 で **NaN boxed nil = `0xFFFD_0000_0000_0000`** が
  即値で得られるので、空リスト判定が `v == .nil_val` で済む

`seq()` がこの哲学を体現:

```zig
pub fn seq(val: Value) Value {
    return switch (val.tag()) {
        .list => if (val.decodePtr(*Cons).count > 0) val else .nil_val,
        else => .nil_val,
    };
}
```

`(seq xs)` は **「使えるコレクションなら自身、空なら nil」** という
Clojure 慣習を 5 行で表現しています。

### 演習 5.2: cons / first / rest / countOf を再構成 (L2 — 部分再構成)

シグネチャだけ与える:

```zig
pub const Cons = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    first: Value,
    rest: Value,
    meta: Value,
    count: u32,
};

pub fn cons(alloc: std.mem.Allocator, head: Value, tail: Value) !Value {
    // ここから書く
}
pub fn first(val: Value) Value {
    // ここから書く (nil semantics)
}
pub fn rest(val: Value) Value {
    // ここから書く (nil semantics)
}
pub fn countOf(val: Value) u32 {
    // ここから書く (nil semantics)
}
```

ヒント:

- `cons` は `alloc.create(Cons)` でセル確保 → 値で埋める →
  `Value.encodeHeapPtr(.list, cell)` で encode して返す
- `count` は `1 + countOf(tail)` で precompute
- 全関数が `val.tag()` で `.list` 以外を fallthrough

<details>
<summary>答え</summary>

```zig
pub fn cons(alloc: std.mem.Allocator, head: Value, tail: Value) !Value {
    const cell = try alloc.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.list),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),
    };
    return Value.encodeHeapPtr(.list, cell);
}

pub fn first(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).first,
        else => .nil_val,
    };
}

pub fn rest(val: Value) Value {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).rest,
        else => .nil_val,
    };
}

pub fn countOf(val: Value) u32 {
    return switch (val.tag()) {
        .list => val.decodePtr(*Cons).count,
        else => 0,
    };
}
```

検証:

```zig
test "structural sharing across cons calls" {
    const tail = try cons(alloc, two, try cons(alloc, three, .nil_val));
    const a = try cons(alloc, one, tail);
    const b = try cons(alloc, zero, tail);
    // 同じ tail を共有
    try testing.expectEqual(@intFromEnum(rest(a)), @intFromEnum(rest(b)));
    try testing.expectEqual(@as(u32, 3), countOf(a));
    try testing.expectEqual(@as(u32, 3), countOf(b));
}
```

</details>

---

## 3. Murmur3 hash — Java と bit 互換にする

`src/runtime/hash.zig` 14-18 行:

```zig
const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const SEED: u32 = 0;
```

これは `clojure.lang.Murmur3` のクラス定数と **完全に一致して
います**。`~/Documents/OSS/clojure/src/jvm/clojure/lang/Murmur3.java`
を覗くと同じマジック定数が並んでいます。

### 3 つのコア関数

```zig
fn mixK1(k: u32) u32 {
    var k1 = k;
    k1 *%= C1;                          // ← wrapping multiply
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= C2;
    return k1;
}

fn mixH1(h: u32, k1: u32) u32 {
    var h1 = h;
    h1 ^= k1;
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% 0xe6546b64;         // ← wrapping multiply + add
    return h1;
}

fn fmix(h: u32, length: u32) u32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= h1 >> 16;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    h1 *%= 0xc2b2ae35;
    h1 ^= h1 >> 16;
    return h1;
}
```

役割:

- `mixK1(k)` — 入力 1 ブロックを撹拌
- `mixH1(h, k1)` — 過去の hash と新ブロックを混ぜる
- `fmix(h, length)` — finalisation。avalanche を起こす

### `*%` / `+%` の必然性

Java の `int` 乗算は **silent overflow**（wrapping）します。一方
Zig の `*` はオーバーフロー時に **panic** または **UB**（debug
ビルドでは前者）になります。これでは Java と挙動が一致しないため、
**`*%` / `+%`**（wrapping arithmetic）を使います。

```zig
k1 *%= C1;          // Java: k1 *= C1; (silent overflow)
h1 = h1 *% 5 +% 0xe6546b64;
```

これがないと最初の `hashInt(0xFFFFFFFE)` で panic してしまい、
Clojure JVM のハッシュ値とも一致しなくなります。

### `hashInt(0)` が **0 を返す**特殊扱い

```zig
pub fn hashInt(input: i32) u32 {
    if (input == 0) return 0;          // ← 早期リターン
    const k1 = mixK1(@bitCast(input));
    const h1 = mixH1(SEED, k1);
    return fmix(h1, 4);
}
```

Java 側にも同じ early return が入っています。なぜでしょうか。
Murmur3 を 0 に通すと、`mixK1(0) = 0` でありながら `fmix(0, 4) ≠ 0`
になるからです。「0 と非 0 を見分けたい」という **辞書順 / 配列の
sentinel 用途** のために、Clojure は `hash(0) == 0` を意図的に
保証しています。

### 演習 5.3: Murmur3 hash モジュール全体を再構成 (L3)

ファイル名と公開 API のみ:

- File: `src/runtime/hash.zig`
- 公開 API:
  - `pub fn hashInt(input: i32) u32`
  - `pub fn hashLong(input: i64) u32`
  - `pub fn hashString(input: []const u8) u32`
  - `pub fn mixCollHash(hash_val: u32, count: u32) u32`
  - `pub fn hashOrdered(hashes: []const u32) u32`
  - `pub fn hashUnordered(hashes: []const u32) u32`

ヒント:

- マジック定数 `C1 = 0xcc9e2d51`、`C2 = 0x1b873593`、`SEED = 0`
- `mixK1` / `mixH1` / `fmix` を内部 helper として定義
- 全演算は wrapping (`*%` / `+%`)
- `hashInt(0)` / `hashLong(0)` は 0 を返す（Java compat）
- `hashOrdered`: `h := 31*h + element`、最後に `mixCollHash`
- `hashUnordered`: `h := h + element` (順序非依存)

<details>
<summary>答え骨子</summary>

```zig
//! Murmur3 hash for ClojureWasm — Clojure-compatible hash values.

const std = @import("std");

const C1: u32 = 0xcc9e2d51;
const C2: u32 = 0x1b873593;
const SEED: u32 = 0;

fn mixK1(k: u32) u32 {
    var k1 = k;
    k1 *%= C1;
    k1 = std.math.rotl(u32, k1, 15);
    k1 *%= C2;
    return k1;
}

fn mixH1(h: u32, k1: u32) u32 {
    var h1 = h;
    h1 ^= k1;
    h1 = std.math.rotl(u32, h1, 13);
    h1 = h1 *% 5 +% 0xe6546b64;
    return h1;
}

fn fmix(h: u32, length: u32) u32 {
    var h1 = h;
    h1 ^= length;
    h1 ^= h1 >> 16;
    h1 *%= 0x85ebca6b;
    h1 ^= h1 >> 13;
    h1 *%= 0xc2b2ae35;
    h1 ^= h1 >> 16;
    return h1;
}

pub fn hashInt(input: i32) u32 {
    if (input == 0) return 0;
    const k1 = mixK1(@bitCast(input));
    const h1 = mixH1(SEED, k1);
    return fmix(h1, 4);
}

pub fn hashLong(input: i64) u32 {
    if (input == 0) return 0;
    const bits: u64 = @bitCast(input);
    const low: u32 = @truncate(bits);
    const high: u32 = @truncate(bits >> 32);
    var h1 = mixH1(SEED, mixK1(low));
    h1 = mixH1(h1, mixK1(high));
    return fmix(h1, 8);
}

pub fn hashString(input: []const u8) u32 {
    var h1: u32 = SEED;
    const nblocks = input.len / 4;

    for (0..nblocks) |i| {
        const offset = i * 4;
        const k: u32 = @as(u32, input[offset]) |
            (@as(u32, input[offset + 1]) << 8) |
            (@as(u32, input[offset + 2]) << 16) |
            (@as(u32, input[offset + 3]) << 24);
        h1 = mixH1(h1, mixK1(k));
    }

    const tail_offset = nblocks * 4;
    var k1: u32 = 0;
    const tail_len = input.len - tail_offset;
    if (tail_len >= 3) k1 ^= @as(u32, input[tail_offset + 2]) << 16;
    if (tail_len >= 2) k1 ^= @as(u32, input[tail_offset + 1]) << 8;
    if (tail_len >= 1) {
        k1 ^= @as(u32, input[tail_offset]);
        h1 ^= mixK1(k1);
    }
    return fmix(h1, @truncate(input.len));
}

pub fn mixCollHash(hash_val: u32, count: u32) u32 {
    var h1 = SEED;
    const k1 = mixK1(hash_val);
    h1 = mixH1(h1, k1);
    return fmix(h1, count);
}

pub fn hashOrdered(hashes: []const u32) u32 {
    var h: u32 = 1;
    for (hashes) |elem_hash| {
        h = h *% 31 +% elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}

pub fn hashUnordered(hashes: []const u32) u32 {
    var h: u32 = 0;
    for (hashes) |elem_hash| {
        h +%= elem_hash;
    }
    return mixCollHash(h, @truncate(hashes.len));
}
```

検証: `hashInt(0) == 0` / `hashLong(0) == 0` / `hashOrdered([1,2]) !=
hashOrdered([2,1])` / `hashUnordered([1,2,3]) == hashUnordered([3,1,2])`。

</details>

---

## 4. UTF-8 を hash する vs UTF-16

`hash.zig` 9-12 行のコメント:

```
//! `hashString` hashes UTF-8 bytes directly, **not** the UTF-16 code
//! units that Clojure JVM hashes. This matches v1's choice and trades
//! exact-bit compatibility for working in a Wasm/edge environment
//! where UTF-8 is the natural encoding.
```

トレードオフ：

- **採用**: UTF-8 byte を直接 hash → Wasm / WASI / edge runtime の
  自然なエンコーディングに一致
- **却下**: Java の UTF-16 string と完全に bit 互換 → JS の `String`
  / Java の `String.hashCode()` と一致するが、Zig 側で全 string を
  一度 UTF-16 にデコードする overhead が発生する

ClojureWasm v2 は **Wasm 第一** なので前者を採用しています。
**互換性を諦める代わりに、速度と素直さを取る** 判断です。これは
ROADMAP **P11（Observable-semantics compatibility）** の枠組みで
「Java の `hashCode` と一致させる」ことは inside detail（観測可能
意味論の外側）と整理しているためです。

---

## 5. 設計判断と却下した代替

| 案                                     | 採否 | 理由                                                                       |
|----------------------------------------|------|----------------------------------------------------------------------------|
| **cons cell + precomputed count: u32** | ✓   | structural sharing と O(1) count を両立、`(count xs)` が hot path で潰せる |
| count を持たない                       | ✗   | `(count xs)` が O(n)、benchmark で痛い                                     |
| 空リスト = sentinel cell               | ✗   | nil semantics の重複、ヒープに永続 root が増える                           |
| `meta: ?Value`                         | ✗   | optional は別の bit を食う、`nil_val` という即値で十分                     |
| **Murmur3 (Clojure 互換)**             | ✓   | Java と同じ value-hash → 移植テストの再現性                               |
| SipHash 採用                           | ✗   | Clojure JVM と非互換、value hash の round-trip 不可                        |
| FNV-1a                                 | ✗   | collision 多、Murmur3 ほど均等でない                                       |
| UTF-16 で hashString                   | ✗   | Wasm/edge で UTF-8 が自然、変換 overhead                                   |
| `*` (panicking multiply)               | ✗   | overflow 時に panic、Java と bit 不一致                                    |

ROADMAP §A6 (≤ 1000 LOC) / §4.2 (NaN boxed Value) / P11 (observable
semantics) と整合。

---

## 6. 確認 (Try it)

```sh
# list だけのスナップショット
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout 902e22d
zig build test     # list.zig の test 群が緑（8 ケース）

# hash まで進めたスナップショット
git checkout 1825f24
zig build test     # hash.zig の test 群もさらに緑（7 ケース）

git checkout cw-from-scratch
```

list の structural sharing を **目で見る**:

```zig
const tail = try cons(alloc, two, try cons(alloc, three, .nil_val));
const a = try cons(alloc, one, tail);
const b = try cons(alloc, zero, tail);

std.debug.print("a.rest = 0x{X:0>16}\n", .{@intFromEnum(rest(a))});
std.debug.print("b.rest = 0x{X:0>16}\n", .{@intFromEnum(rest(b))});
// → 同じ pointer (cell address shifted)
```

---

## 7. 教科書との対比

| 軸              | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref                         | Clojure JVM           | 本リポ                         |
|-----------------|-------------------------------------------|--------------------------------|-----------------------|--------------------------------|
| List 表現       | `collections.zig` 6K LOC 内に同居         | `collection/list.zig` (172 行) | `PersistentList.java` | `collection/list.zig` (173 行) |
| count storage   | precompute あり                           | precompute あり                | precompute あり       | precompute あり                |
| empty list      | sentinel cell                             | nil 代用                       | `EMPTY` sentinel      | nil 代用                       |
| Hash impl       | `hash.zig` 187 行                         | `hash.zig` 224 行              | `Murmur3.java` (Java) | `hash.zig` 179 行              |
| String hash     | UTF-8                                     | UTF-8                          | UTF-16                | UTF-8 (Wasm 第一)              |
| Wrapping arithm | `*%` / `+%`                               | `*%` / `+%`                    | silent (Java int)     | `*%` / `+%`                    |

引っ張られずに本リポジトリの理念で整理した点：

- v1 の `collections.zig`（6K LOC）は §A6 の典型的な失敗例です。
  本リポジトリは list / vector / hamt にファイルを分割しています
  （hamt / vector の追加は Phase 6+ を予定）。
- Clojure JVM の `EMPTY` sentinel は永続 root が 1 cell ぶん heap
  に常駐することになります。v2 では nil で代用するため、**GC root
  が 1 個減ります**。
- UTF-8 hash: JVM 互換を諦める代わりに、Wasm 上での文字列計算で
  「デコードが不要」になります。

---

## 8. Feynman 課題

1. なぜ cons cell に `count: u32` を持たせるのか。1 行で。
2. `*%`（wrapping multiply）と `*`（通常の multiply）の差は何か。
   1 行で。
3. 空リストを sentinel cell ではなく nil で表す利点は何か。1 行で。

---

## 9. チェックリスト

- [ ] 演習 5.1: nil semantics の振る舞いを 5 ケース予測できる
- [ ] 演習 5.2: `cons` / `first` / `rest` / `countOf` を
      シグネチャだけから書ける
- [ ] 演習 5.3: `hash.zig` 全体を公開 API のリストだけから書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] Murmur3 のマジック定数 `C1` / `C2` がなぜそのままか説明できる
- [ ] ROADMAP §A6 / §P11 を即座に指せる

---

## 次へ

第 6 章: [Keyword interning — 安定した cell layout](./0006-keyword-intern.md)

— `:foo` を **identity 比較** で済ませるための intern table の作り
方を学びます。heap-allocated cell にレイアウトを固定し、Phase 2.2
で rt-aware へ昇格させる伏線まで含めて見ていきます。
