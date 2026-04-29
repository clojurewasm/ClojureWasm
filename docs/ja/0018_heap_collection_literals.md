<!-- Per-concept chapter. docs/ja/0018_heap_collection_literals.md -->

---
chapter: 18
commits:
  - 3a5f852
  - 766a73a
related-tasks:
  - §9.5/3.5
  - §9.5/3.6
related-chapters:
  - 17
  - 19
date: 2026-04-27
---

# 18 — Heap collection literals as Values

> 対応 task: §9.5 / 3.5 + 3.6 / 所要時間: ~50 分

Phase 2 までの ClojureWasm v2 は immediate Value（NaN-boxed の
integer / float / boolean / nil / keyword / char / builtin_fn）しか
expression として受け付けていませんでした。3.5 と 3.6 でようやく
heap-backed Value が 2 種類解禁されます。**String** と **List** です。
本章では、この 2 つのタスクが共有している「heap 型を 1 つ追加する
ときの型レシピ」を読み解きます。

---

## この章で学ぶこと

- HeapTag が 8 種類の heap-backed Value をどう識別するか、`encodeHeapPtr` で
  Value にどう焼き込まれるか
- `rt.gpa.dupe` + `rt.trackHeap` がなぜ Value lifetime の正解で、per-eval
  arena では駄目なのか
- `(quote (1 2 3))` を実行したとき Form → Value lift がどの段で起き、
  printer がどう逆走するか
- v1 の inline-tail 最適化 / Clojure JVM の PersistentList$EMPTY を
  「あえて採らない」判断と、そのトレードオフ

---

## 1. HeapTag と heap 型レシピ

`runtime/value.zig` の `Value` は 64-bit NaN-boxed payload。下位 4 bit
の `HeapTag` で 8 種類の heap object を区別する：

```zig
pub const HeapTag = enum(u8) {
    // immediate-only tags 略...
    string,
    cons,            // (= List)
    fn_val,
    keyword,
    transient_vector,
    // ...
};
```

heap 型を 1 つ増やすたびに、必ず 4 つのファイルを揃って触る：

| ファイル                        | やること                                               |
|---------------------------------|--------------------------------------------------------|
| `runtime/value.zig`             | `HeapTag` に enum 値を追加（既に全種揃っていれば不要） |
| `runtime/collection/<name>.zig` | struct と `alloc(rt, ...)` と `freeXxx` を新設         |
| `eval/analyzer.zig`             | 該当 Form arm から `xxx.alloc` を呼んで Value に lift  |
| `src/main.zig::printValue`      | pr-str 形式の描画分岐を追加                            |

これは **A2「新機能は新ファイル」** と **P3「core stays stable」** を体現
した「足し算だけで進む」経路。3.5 と 3.6 はまさにこのレシピを 2 回
連続で踏むタスクだった。

### 演習 18.1: HeapTag が 4-bit の意味 (L1 — predict)

```zig
pub const HeapTag = enum(u8) {
    nil = 0,
    boolean = 1,
    integer = 2,
    float = 3,
    char = 4,
    builtin_fn = 5,
    keyword = 6,
    string = 7,
    cons = 8,
    fn_val = 9,
    // ...
};
```

Q1: `HeapTag` の **値域** が 0–15 に収まる必要があるのはなぜか？  
Q2: `Value.tag()` は `enum(u8)` で宣言されているのに、なぜ実際の用途は
4-bit に制約されているのか？  

<details>
<summary>答え</summary>

**Q1**: NaN-boxing の payload は 64-bit のうち上位 13 bit が
"quiet NaN signature"、下位 48 bit が pointer payload、その間の **4 bit**
が tag 領域。15 を超える tag は別 bit に侵食して NaN-box が壊れる。

**Q2**: `enum(u8)` は記憶域型。コードの取り回しは 8-bit でも、Value への
書き込み時 (`encodeHeapPtr`) に 4-bit field へ閉じ込める。`@intCast` で
overflow すれば runtime panic — 4-bit を超えた tag は **コンパイルでは
気づけず実行時に死ぬ**ので、enum 定義時点で人間が守る。

</details>

---

## 2. lifetime: arena vs `rt.gpa` + `trackHeap`

3.6 でいちばん詰まったのは「`(quote (1 2 3))` の List Value はどの
allocator から取るべきか」だった。素朴には analyzer の per-eval arena
を使いたくなる：

```zig
// 誤った設計
fn listFormToValue(arena: std.mem.Allocator, items: []const Form) !Value {
    var acc: Value = .nil_val;
    var i = items.len;
    while (i > 0) {
        i -= 1;
        const head = try formToValue(arena, items[i]);
        acc = try list_collection.cons(arena, head, acc);  // arena に Cons を作る
    }
    return acc;
}
```

これは `(def x (quote (1 2 3)))` で破綻する。`def` は Var に Value を
bind するが、analyzer arena は **次の式の analyse が始まる前に reset
される** — Var が抱えた `*Cons` ポインタは即時 dangling pointer になる。

正解は heap allocator (`rt.gpa`) 経由で Cons を確保し、`rt.trackHeap`
で `Runtime.deinit` 時に解放するよう登録すること：

```zig
// list.zig 抜粋（実物）
pub fn consHeap(rt: *Runtime, head: Value, tail: Value) !Value {
    const cell = try rt.gpa.create(Cons);
    cell.* = .{
        .header = HeapHeader.init(.cons),
        .first = head,
        .rest = tail,
        .meta = .nil_val,
        .count = 1 + countOf(tail),
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(cell), .free = freeCons });
    return Value.encodeHeapPtr(.cons, cell);
}
```

ここで重要なのは **既存の `cons(alloc, ...)` を消さなかった**こと。
unit test では arena allocator を渡したい (テスト終了時 bulk free が楽)
ので、両方 export して用途で使い分ける：

| 関数                 | allocator            | 用途                                        |
|----------------------|----------------------|---------------------------------------------|
| `cons(alloc, h, t)`  | 任意                 | unit test、phase-internal な短命 List       |
| `consHeap(rt, h, t)` | `rt.gpa` + trackHeap | production code、Var に bind され得る Value |

これは Phase 5+ で mark-sweep GC が入るまでの暫定構造。GC 移行時には
`trackHeap` の callback リストごと「GC root テーブル」に置き換わる。

### 演習 18.2: lifetime 違反を作って壊す (L2 — partial reconstruction)

`listFormToValue` を **arena 借用版**で書いたとして、どの cljw 実行が
壊れるか予測せよ。次のコードの `???` を埋め、もし入ってしまっていたら
実際に何が起きるか答えよ。

```zig
// (誤) listFormToValue が arena を使う場合
fn listFormToValue_BAD(rt: *Runtime, arena: std.mem.Allocator, items: []const Form) !Value {
    var acc: Value = .nil_val;
    var i = items.len;
    while (i > 0) : (i -= 1) {
        const head = try formToValue(rt, arena, items[i - 1]);
        acc = try list_collection.cons(arena, head, acc);  // ★
    }
    return acc;
}
```

ヒント:
- main.zig は per-form ループで analyze → eval を回し、ループ末で
  arena を reset する設計
- `(def x ???)` の Var.root には Value がコピーで入る
- 後続の `(prn x)` のときには arena は既に何回か reset されている

<details>
<summary>答え</summary>

壊れる cljw 入力例 (heredoc):

```clojure
(def x (quote (1 2 3)))
(prn x)
```

挙動：

1. 1 行目 analyse: arena に `Cons{1 → 2 → 3 → nil}` を 3 個確保。
   Value は `Cons{1, ...}` ポインタ → encodeHeapPtr。Var `x.root` に
   この Value をコピー。
2. 1 行目 eval: 何もしない（quote）。print → `(1 2 3)`。
3. **arena reset**（main.zig のループ仕様による）。
4. 2 行目 analyse: `prn` が var_ref `x` を見つける、deref で Value
   取得。**Value 内の pointer はもう free 領域を指している**。
5. eval: `prn` が printValue を呼び、`val.decodePtr(*Cons)` が **解放
   済み領域の bit pattern** を Cons として読む → Cons.first は乱数。
   出力は `(<garbage> <garbage> <garbage>)` か segfault。

`consHeap` ならば `rt.gpa` 上で確保して `Runtime.deinit` まで生存する
ので、Var が抱えるポインタは process 終了まで valid。

</details>

---

## 3. heap String の 1-alloc + dupe レシピ

`runtime/collection/string.zig` は heap-backed value 増設の **最小例**：

```zig
pub const String = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    bytes: []const u8,

    comptime {
        std.debug.assert(@alignOf(String) >= 8);
    }
};

pub fn alloc(rt: *Runtime, bytes: []const u8) !Value {
    const owned = try rt.gpa.dupe(u8, bytes);
    errdefer rt.gpa.free(owned);
    const s = try rt.gpa.create(String);
    s.* = .{ .header = HeapHeader.init(.string), .bytes = owned };
    try rt.trackHeap(.{ .ptr = @ptrCast(s), .free = freeString });
    return Value.encodeHeapPtr(.string, s);
}

fn freeString(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const s: *String = @ptrCast(@alignCast(ptr));
    gpa.free(s.bytes);
    gpa.destroy(s);
}
```

注目点：

1. **`_pad: [6]u8`** — `HeapHeader` が 2 byte なので、続く `bytes` slice
   ポインタの 8-byte alignment を確保するための明示パディング。`comptime
   assert(@alignOf(String) >= 8)` がコンパイル時に守る。NaN-boxed
   pointer encoding は **下位 3 bit を 0 にする** ことを要求するので
   alignment が崩れると即時 panic。
2. **`errdefer rt.gpa.free(owned)`** — `dupe` は成功したが `create` で
   OOM、というパスで bytes が orphan するのを防ぐ。Zig の `errdefer` は
   try が rebind するときだけ走るので、successful path では free
   されない。
3. **`alloc` の戻り値は `Value`** — String pointer をそのまま渡さない。
   `encodeHeapPtr(.string, s)` で NaN-box し、tag bits も焼く。

print 側 (`main.zig::printString`) は対称な escape table を持つ：

```zig
fn printString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        '\r' => try w.writeAll("\\r"),
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}
```

これと Reader の `unescapeString` (§9.4 / 1.9) が **対称**であること、
すなわち `read-string ∘ pr-str = id` が ASCII 範囲で成り立つことが
3.5 の暗黙の不変条件。escape 表に `\u{xxxx}` を足したくなったら、
Reader 側にも対応エントリが要る。

### 演習 18.3: ゼロから書く `runtime/collection/string.zig` (L3 — full reconstruction)

要求:
- File: `src/runtime/collection/string.zig`
- Public:
  - `pub const String = struct { ... };` (header + bytes、8-byte alignment)
  - `pub fn alloc(rt: *Runtime, bytes: []const u8) !Value`
  - `pub fn asString(val: Value) []const u8`
- 内部:
  - `fn freeString(gpa, ptr) void`
- Test:
  - alloc/asString round-trip
  - dupe による source mutation 隔離
  - 空文字列の扱い
  - Runtime.deinit がリーク無く解放することの確認 (testing.allocator が gate)

<details>
<summary>答え骨子</summary>

```zig
//! Heap-backed string Value.

const std = @import("std");
const value_mod = @import("../value.zig");
const Value = value_mod.Value;
const HeapHeader = value_mod.HeapHeader;
const Runtime = @import("../runtime.zig").Runtime;

pub const String = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    bytes: []const u8,

    comptime {
        std.debug.assert(@alignOf(String) >= 8);
    }
};

pub fn alloc(rt: *Runtime, bytes: []const u8) !Value {
    const owned = try rt.gpa.dupe(u8, bytes);
    errdefer rt.gpa.free(owned);
    const s = try rt.gpa.create(String);
    s.* = .{ .header = HeapHeader.init(.string), .bytes = owned };
    try rt.trackHeap(.{ .ptr = @ptrCast(s), .free = freeString });
    return Value.encodeHeapPtr(.string, s);
}

fn freeString(gpa: std.mem.Allocator, ptr: *anyopaque) void {
    const s: *String = @ptrCast(@alignCast(ptr));
    gpa.free(s.bytes);
    gpa.destroy(s);
}

pub fn asString(val: Value) []const u8 {
    std.debug.assert(val.tag() == .string);
    return val.decodePtr(*String).bytes;
}
```

検証: `bash test/run_all.sh` が緑になる。`zig build && ./zig-out/bin/cljw -e '"hello"'` → `"hello"`。

</details>

---

## 4. 設計判断と却下した代替

### 4.1 heap String

| 案                                                                           | 採否      | 理由                                                                              |
|------------------------------------------------------------------------------|-----------|-----------------------------------------------------------------------------------|
| 案 A: inline tail bytes (`String { header, len, inline: [N]u8 }`) で 1 alloc | ✗        | 任意長文字列で size-branching が必要、複雑度過剰。Phase 8 GC + interning で再検討 |
| 案 B: bytes を arena 借用 (dupe しない)                                      | ✗        | arena reset で Value が dangle、Var に bind されると即 use-after-free             |
| 案 C: print 時に escape **しない** (生バイト)                                | ✗        | pr-str round-trip が壊れる、Clojure REPL 慣習からも外れる                         |
| 案 D: string interning (同一バイト列で pointer 共有)                         | ✗ (保留) | Phase 8 の最適化。3.5 段階では複雑度過剰                                          |
| 採用: 1 alloc + `dupe`                                                       | ✓        | 素直、`errdefer` でリーク守れる、Phase 8 で改造容易                               |

### 4.2 heap List

| 案                                                                         | 採否 | 理由                                                                             |
|----------------------------------------------------------------------------|------|----------------------------------------------------------------------------------|
| 案 A: 専用 `EMPTY_LIST` Value sentinel                                     | ✗   | Value identity 比較が複雑化、Phase 5+ GC との整合性で再考                        |
| 案 B: 既存 `cons(alloc, ...)` だけで analyzer arena を rt.gpa に総取り換え | ✗   | arena は per-eval scope、Value lifetime と意図的に分離している設計を崩したくない |
| 案 C: `listFormToValue` を iterative (ArrayList) で書く                    | ✗   | 再帰のほうが items 短いので stack 安全、可読性で勝つ                             |
| 採用: `cons` と `consHeap` を併存させ、空 List → nil で簡略化             | ✓   | 用途で使い分け可、Clojure JVM `()`/`nil` 区別は Phase 8+ で復元可                |

ROADMAP § 2 / 原則 P3「core stays stable」、A2「新機能は新ファイル」、
A6「≤ 1000 lines per file」をすべて満たす。

---

## 5. 確認 (Try it)

```sh
git checkout 766a73a    # 3.6 末尾
zig build
./zig-out/bin/cljw -e '"hello"'
# → "hello"

./zig-out/bin/cljw - <<'EOF'
(quote (1 :a "b"))
EOF
# → (1 :a "b")

./zig-out/bin/cljw - <<'EOF'
(quote ())
EOF
# → nil   (CW v2 の意図的簡略化)

bash test/run_all.sh    # 全 suite green、phase3_cli.sh は 11/11 段階
```

---

## 6. 教科書との対比

| 軸           | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM                           | 本リポジトリ                                            |
|--------------|-------------------------------------------|--------|---------------------------------------|---------------------------------------------------------|
| String 構造  | inline tail bytes 最適化（small-string）  | 未実装 | `java.lang.String` (JVM ネイティブ)   | header + dupe された `[]u8` slice の素朴版              |
| 空 List 表現 | sentinel-Cons (`count=0`)                 | 未実装 | `PersistentList$EmptyList` 専用クラス | `nil_val` で簡略 (Phase 8+ 復元予定)                    |
| 確保所       | GC 経路へ直結                             | 未実装 | JVM heap                              | `rt.gpa.create` + `rt.trackHeap` (Phase 5 で GC へ置換) |
| arena 共存   | なし (全部 GC)                            | 未実装 | なし                                  | `cons(alloc, ...)` をテスト用に温存                     |

引っ張られずに本リポジトリの理念で整理した点：

- v1 の inline-tail 最適化は性能チューニングであり、3.5 の段階で
  導入すると「学習リポにとっての教科書的な配列」を壊してしまいます。
  Phase 8 の専用最適化フェーズで再評価する予定です。
- Clojure JVM の `()` と `nil` の区別は EmptyList class hierarchy が
  支えています。CW v2 は Value tag が単一（`HeapTag.cons`）で、
  `(quote ())` → `nil_val` という簡略化を選びました。**これは欠落
  ではなく一時的な妥協** であり、Phase 8+ で sentinel 化、もしくは
  専用 Value variant を ADR で固める想定です。

---

## 7. Feynman 課題

6 歳の自分に説明するつもりで答えてください。書けなければ理解が不完全
だと判断し、その節を読み直します。

1. なぜ Value を作る関数のうち、`String` と `Cons` は `rt.gpa` を
   使い、`Integer` や `Boolean` は使わないのか。1 行で。
2. `(quote (1 2 3))` を実行すると Form は何回 traverse されるか。
   1 回か 2 回か、そしてそれぞれ何のためか。
3. `_pad: [6]u8 = undefined` を消すと何が起きるか。何 byte ずれて、
   どの assert が叫ぶか。

---

## 8. チェックリスト

- [ ] 演習 18.1 の答えを書ける（4-bit 制約と enum(u8) の関係）
- [ ] 演習 18.2 を試行錯誤なしで書ける（arena 借用が壊すシナリオ）
- [ ] 演習 18.3 を `string.zig` のファイル名と API リストだけから書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] ROADMAP §9.5 / 3.5 と 3.6 を即座に指せる
- [ ] `cons` と `consHeap` の使い分け（テスト用 / production 用）を即答
- [ ] HeapTag の 4-bit 制約の根拠（NaN-box layout）を即答

---

## 次へ

第 19 章: [macroexpand routing と ADR 0001](./0019_macroexpand_routing.md)
