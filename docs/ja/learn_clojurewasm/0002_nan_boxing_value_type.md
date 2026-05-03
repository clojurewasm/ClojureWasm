---
chapter: 2
commits:
  - 8b487f9
related-tasks:
  - §9.3 / 1.1
related-chapters:
  - 0001
  - 0003
date: 2026-04-27
---

# 0002 — NaN boxing による Value 型

> 対応 task: §9.3 / 1.1 / 所要時間: 60〜90 分

すべての Clojure 値を **`u64` 1 個（8 バイト）** に詰め込みます。
整数も浮動小数も nil もキーワードも、ヒープ上の永続リストも、すべて
同じ型 `Value` の 1 値として扱います。これを成立させる仕組みが
**NaN boxing** です。

これを Day 1 から導入しておくことで、Phase 35 で後付けして 1,200
箇所を書き直す羽目になった v1 の轍を踏まずに済みます（ROADMAP
§1.4）。

---

## この章で学ぶこと

- IEEE-754 倍精度浮動小数の **NaN bit pattern** と「余り領域」の正体
- 32 個の Heap スロットを **4 グループ × 8 サブタイプ** で詰める方法
- ヒープアドレスを **48 bit に落とす** ための 8-byte alignment 制約
- nil / true / false の **シングルトン bit パターン**
- `Value.tag()` が定数時間で型を返せる仕組み（band 比較 + 3-bit 読み）

---

## 1. IEEE-754 NaN の余り領域

f64 は 64 bit のうち：

```
sign[63] | exponent[62..52] | mantissa[51..0]
```

**`exponent == 0x7FF` かつ `mantissa != 0`** のときが NaN です。
`mantissa` は 52 bit あるので、NaN bit pattern は **2^52 - 1 通り**
存在します。これらはすべて「数値としては NaN」として等価です。

つまり、**NaN としては "意味のない" mantissa 領域を、自分のデータの
入れ物として使える** ことになります。これが NaN boxing の出発点
です。

### 本リポジトリの上位 16 bit 配置

`src/runtime/value.zig` 冒頭の `//!` doc-comment より:

```
top16 < 0xFFF8                 raw f64 (pass-through)

Heap groups (contiguous 0xFFF8-0xFFFB):
  0xFFF8  Group A  Core Data           sub-type[47:45] | addr>>3 [44:0]
  0xFFF9  Group B  Callable & Binding  sub-type[47:45] | addr>>3 [44:0]
  0xFFFA  Group C  Sequence & State    sub-type[47:45] | addr>>3 [44:0]
  0xFFFB  Group D  Transient & Ext     sub-type[47:45] | addr>>3 [44:0]

Immediate types (contiguous 0xFFFC-0xFFFF):
  0xFFFC  integer     i48, signed; overflow → float promotion
  0xFFFD  constant    0=nil, 1=true, 2=false
  0xFFFE  char        u21 codepoint
  0xFFFF  builtin_fn  48-bit function pointer
```

つまり **上位 16 bit が `0xFFF8` 以上** のときは「NaN boxed の
タグ付き値」、**`0xFFF8` 未満** のときは「素の f64」として扱います。

```
0x0000_0000_0000_0000  ← +0.0
0x3FF0_0000_0000_0000  ← 1.0
0x7FF0_0000_0000_0000  ← +Infinity
0xFFF8_0000_0000_0000  ← Group A タグ start
...
0xFFFF_0000_0000_0000  ← builtin_fn
```

### 演習 2.1: top16 から型を当てる (L1 — 予測検証)

以下の `Value` (u64 として表記) は何型？ それぞれの top16 を読んで
予測してください。

```
v1 = 0x4000_0000_0000_0000     # → ?
v2 = 0xFFF8_0123_4567_8000     # → ?
v3 = 0xFFFC_0000_0000_002A     # → ?
v4 = 0xFFFD_0000_0000_0001     # → ?
v5 = 0xFFFF_0000_1234_5678     # → ?
```

<details>
<summary>答え</summary>

| Value | top16               | 判定                                                     |
|-------|---------------------|----------------------------------------------------------|
| v1    | `0x4000` (< 0xFFF8) | **f64**（具体的には 2.0）                                |
| v2    | `0xFFF8`            | **Group A heap**。続けて sub-type[47:45] = `0` → string |
| v3    | `0xFFFC`            | **integer**。下位 48 bit = `0x2A` = **42**               |
| v4    | `0xFFFD`            | **constant**。下位 = `1` → **true**                     |
| v5    | `0xFFFF`            | **builtin_fn**。下位 48 bit が関数ポインタ               |

</details>

---

## 2. Heap 32 スロットの 4×8 配置

Heap オブジェクトは全部で 32 種類ありますが、これを **4 グループ ×
8 サブタイプ** で詰めるのが本リポジトリの工夫です。

```
| Group (band)          | Sub 0    | Sub 1    | Sub 2     | Sub 3       | Sub 4   | Sub 5   | Sub 6    | Sub 7    |
|-----------------------|----------|----------|-----------|-------------|---------|---------|----------|----------|
| A: Core Data (0xFFF8) | string   | symbol   | keyword   | list        | vector  | arr_map | hash_map | hash_set |
| B: Call/Bind (0xFFF9) | fn_val   | multi_fn | protocol  | protocol_fn | var_ref | ns      | delay    | regex    |
| C: Seq/State (0xFFFA) | lazy_seq | cons     | chunked_c | chunk_buf   | atom    | agent   | ref      | volatile |
| D: Trans/Ext (0xFFFB) | t_vector | t_map    | t_set     | reduced     | ex_info | wasm_m  | wasm_fn  | class    |
```

このレイアウトの仕組み：

- **タグ band** は `top16` の下位 2 bit（`0xFFF8` の `8` 部分）で
  4 値を区別。
- **サブタイプ** は bits[47:45] の 3 bit（8 値）で区別。
- 残り bits[44:0] = 45 bit が **payload**（ヒープアドレス >> 3 など）。

```
0xFFF8_0..._....   Group A
       ↑↑↑           sub-type (3 bit) at [47:45]
          ↓↓↓↓↓↓↓
          payload (45 bit) at [44:0]
```

### なぜ 4 グループに分けるのか

「**型のグループ単位での判定**」を 1 命令で済ませるためです。例：

```zig
// "これはコレクションか？" → Group A の sub 3..7
fn isPersistentColl(v: Value) bool {
    const top16 = @as(u16, @truncate(@intFromEnum(v) >> 48));
    if (top16 != 0xFFF8) return false;
    const sub = @as(u8, @truncate((@intFromEnum(v) >> 45) & 0x7));
    return sub >= 3;
}
```

実際には `tag()` メソッドが 1 つの `switch` でまとめて処理するので、
グループ分けはむしろ **将来の最適化のための地ならし** として効いて
きます。

### 演習 2.2: HeapTag 番号からグループを引く (L2)

`src/runtime/value.zig` の `HeapTag` enum は 0-31 の整数値を持つ：

```zig
pub const HeapTag = enum(u8) {
    string = 0,    // Group A, sub 0
    ...
    fn_val = 8,    // Group B, sub 0
    ...
    class = 31,    // Group D, sub 7
};
```

**シグネチャだけ与えるので、本体を書いてください**：

```zig
fn groupOf(ht: HeapTag) u2 {
    // 0 → A, 1 → B, 2 → C, 3 → D
}
fn subOf(ht: HeapTag) u3 {
    // 0..7
}
```

<details>
<summary>答え</summary>

```zig
fn groupOf(ht: HeapTag) u2 {
    return @truncate(@intFromEnum(ht) / 8);
}
fn subOf(ht: HeapTag) u3 {
    return @truncate(@intFromEnum(ht) % 8);
}
```

実際の `Value.encodeHeapPtr` でも同じ pattern が使われています：

```zig
const type_val = @intFromEnum(ht);
const group = type_val / NB_HEAP_GROUP_SIZE;        // 8
const sub_type = type_val % NB_HEAP_GROUP_SIZE;     // 0..7
```

</details>

---

## 3. ヒープアドレスを 48 bit に落とす

x86_64 / ARM64 の **仮想アドレス空間は実用上 48 bit**（user 空間）
です。さらに **8-byte alignment** を強制すれば、下位 3 bit が常に 0
になるので **`addr >> 3` で 45 bit に圧縮** できます。

```
addr = 0x0000_7FFE_BCDE_1234   (元のアドレス、48 bit; ただし alignment 違反)
→ assert(addr & 0x7 == 0)       (8-byte 整列確認)
→ addr & 0x7 == 0 のとき下位 3 bit = 0
→ addr >> 3 = 0x0000_0FFF_D79B_C246  (45 bit)
```

### `Value.encodeHeapPtr` の中身

```zig
pub fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value {
    const addr: u64 = @intFromPtr(ptr);
    std.debug.assert(addr & NB_ADDR_ALIGN_MASK == 0);   // ← 8-byte align
    const shifted = addr >> NB_ADDR_ALIGN_SHIFT;        // ← >> 3
    std.debug.assert(shifted <= NB_ADDR_SHIFTED_MASK);  // ← 45 bit に収まる

    const type_val = @intFromEnum(ht);
    const group = type_val / NB_HEAP_GROUP_SIZE;
    const tag_base: u64 = switch (group) {
        0 => NB_HEAP_TAG_A,   // 0xFFF8_...
        1 => NB_HEAP_TAG_B,   // 0xFFF9_...
        2 => NB_HEAP_TAG_C,   // 0xFFFA_...
        3 => NB_HEAP_TAG_D,   // 0xFFFB_...
        else => unreachable,
    };
    const sub_type: u64 = type_val % NB_HEAP_GROUP_SIZE;
    return @enumFromInt(tag_base | (sub_type << NB_HEAP_SUBTYPE_SHIFT) | shifted);
}
```

### 8-byte alignment の確保

ヒープオブジェクトは **必ず 8-byte aligned** で確保する必要が
あります。これは Zig の `std.mem.Allocator` がデフォルトで満たして
くれますが、自前レイアウトでは `extern struct` の先頭に **8-byte
ヘッダ** を置いて保証する慣習があります（次章以降で `HeapHeader`
を取り上げます）。

### 演習 2.3: encodeHeapPtr / decodePtr を書き起こす (L3)

ファイル名と公開 API のみ：

```zig
// File: src/runtime/value.zig (一部)
//
// const HeapTag = enum(u8) { string=0, symbol=1, ..., class=31 };
// const NB_HEAP_TAG_A: u64 = 0xFFF8_0000_0000_0000;
// const NB_HEAP_TAG_B: u64 = 0xFFF9_0000_0000_0000;
// const NB_HEAP_TAG_C: u64 = 0xFFFA_0000_0000_0000;
// const NB_HEAP_TAG_D: u64 = 0xFFFB_0000_0000_0000;
//
// pub fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value;
// pub fn decodePtr(self: Value, comptime T: type) T;
```

**実装してみてください**。エンコード後にデコードして元のポインタが
戻ることをテストします。

<details>
<summary>答え骨子</summary>

```zig
const NB_HEAP_SUBTYPE_SHIFT: u6 = 45;
const NB_ADDR_ALIGN_SHIFT: u3 = 3;
const NB_ADDR_SHIFTED_MASK: u64 = 0x0000_1FFF_FFFF_FFFF;
const NB_HEAP_GROUP_SIZE: u8 = 8;

pub fn encodeHeapPtr(ht: HeapTag, ptr: anytype) Value {
    const addr: u64 = @intFromPtr(ptr);
    std.debug.assert(addr & 0x7 == 0);
    const shifted = addr >> NB_ADDR_ALIGN_SHIFT;
    std.debug.assert(shifted <= NB_ADDR_SHIFTED_MASK);

    const type_val = @intFromEnum(ht);
    const group = type_val / NB_HEAP_GROUP_SIZE;
    const tag_base: u64 = switch (group) {
        0 => NB_HEAP_TAG_A,
        1 => NB_HEAP_TAG_B,
        2 => NB_HEAP_TAG_C,
        3 => NB_HEAP_TAG_D,
        else => unreachable,
    };
    const sub_type: u64 = type_val % NB_HEAP_GROUP_SIZE;
    return @enumFromInt(tag_base | (sub_type << NB_HEAP_SUBTYPE_SHIFT) | shifted);
}

pub fn decodePtr(self: Value, comptime T: type) T {
    const shifted = @intFromEnum(self) & NB_ADDR_SHIFTED_MASK;
    return @ptrFromInt(@as(usize, shifted) << NB_ADDR_ALIGN_SHIFT);
}
```

検証テスト:

```zig
test "encode + decode roundtrip" {
    var dummy: extern struct { _: [8]u8 align(8) } = undefined;
    const v = Value.encodeHeapPtr(.string, &dummy);
    const p = v.decodePtr(*@TypeOf(dummy));
    try std.testing.expectEqual(@intFromPtr(&dummy), @intFromPtr(p));
}
```

</details>

---

## 4. nil / true / false のシングルトン

`Value` enum 自身に 3 つだけ「名前付き定数」が定義されています：

```zig
pub const Value = enum(u64) {
    nil_val   = NB_CONST_TAG | 0,    // 0xFFFD_0000_0000_0000
    true_val  = NB_CONST_TAG | 1,    // 0xFFFD_0000_0000_0001
    false_val = NB_CONST_TAG | 2,    // 0xFFFD_0000_0000_0002
    _,
};
```

`_,` は「他の値も許す」(non-exhaustive enum) という宣言です。
これによって：

- `Value.nil_val` のような **コンパイル時の名前付き定数** が使える
- 同時に `@enumFromInt(任意の u64)` で任意の値を作れる

`(if x ... ...)` の判定は「nil または false 以外は真」なので、
**`isTruthy()`** は 2 値の比較 1 つで済みます：

```zig
pub fn isTruthy(self: Value) bool {
    return self != .nil_val and self != .false_val;
}
```

---

## 5. integer の i48 + float promotion

整数は **48 bit signed (i48)** に限定し、それを超えるものは f64 に
promote します：

```zig
pub fn initInteger(i: i64) Value {
    if (i < NB_I48_MIN or i > NB_I48_MAX) {
        return initFloat(@floatFromInt(i));   // promote
    }
    const raw: u48 = @truncate(@as(u64, @bitCast(i)));
    return @enumFromInt(NB_INT_TAG | @as(u64, raw));
}
```

なぜ i48 か：
- top16 = `0xFFFC` を tag に使う → 残り 48 bit が payload
- 48 bit signed は ±140 兆。実用上の整数値であれば十分

### 演習 2.4: i48 範囲を計算 (L1)

`NB_I48_MIN` と `NB_I48_MAX` の数値は？

<details>
<summary>答え</summary>

`NB_TAG_SHIFT = 48` なので：

```zig
const NB_I48_MIN: i64 = -(1 << 47) = -140737488355328
const NB_I48_MAX: i64 = (1 << 47) - 1 = 140737488355327
```

これを超えると f64 に promote します。Clojure の自動 promotion
慣習と整合しています（v1 も同様）。

</details>

---

## 6. NaN bit pattern の collision 回避

`initFloat` には重要な仕掛けがあります：

```zig
pub fn initFloat(f: f64) Value {
    const bits: u64 = @bitCast(f);
    if ((bits >> NB_TAG_SHIFT) >= NB_FLOAT_TAG_BOUNDARY) {
        return @enumFromInt(NB_CANONICAL_NAN);  // 0x7FF8_...
    }
    return @enumFromInt(bits);
}
```

なぜでしょうか。f64 として「素の NaN」が `bits >> 48 >= 0xFFF8` の
範囲に出現すると、**それは Group A heap タグと衝突します**。`tag()`
で判定すると `.string` や `.list` として誤分類されてしまいます。

対策として、こうした衝突しうる NaN bit pattern は **canonical な
quiet NaN (`0x7FF8_0000_0000_0000`)** に正規化します。これは
top16 < 0xFFF8 の領域に位置するので、ヒープタグと衝突しません。

### 演習 2.5: collision を観察 (L2 — predict-then-verify)

以下のコードの出力を予測してください（`std.math.nan(f64)` の bit
パターンが処理系依存だとして、最悪のケースを想定）：

```zig
const f = std.math.nan(f64);    // top16 = ?
const v = Value.initFloat(f);
std.debug.print("tag = {s}\n", .{@tagName(v.tag())});
```

<details>
<summary>答え</summary>

`std.math.nan(f64)` は通常 `0x7FF8_0000_0000_0000` (canonical
positive quiet NaN) を返すため、`top16 = 0x7FF8 < 0xFFF8` で
`.float` 判定。

ただし「最悪のケース」(`0xFFF8_0000_0000_0001` のような signaling
NaN) を作ったとしても、`initFloat` が canonical NaN に正規化する
ので **常に `.float`** になる。

```
tag = float
```

これが NaN boxing 実装の正しさを保つ要となる仕掛けです。

</details>

---

## 7. `tag()` の定数時間判定

`Value.tag()` の switch:

```zig
pub fn tag(self: Value) Tag {
    const bits = @intFromEnum(self);
    const top16: u16 = @truncate(bits >> NB_TAG_SHIFT);
    if (top16 < NB_FLOAT_TAG_BOUNDARY) return .float;       // ← 1 比較
    const sub: u8 = @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & NB_HEAP_SUBTYPE_MASK);
    return switch (top16) {
        NB_TAG_A => heapTagToTag(sub),
        NB_TAG_B => heapTagToTag(sub + NB_HEAP_GROUP_SIZE),
        NB_TAG_C => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 2),
        NB_TAG_D => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 3),
        NB_TAG_INT => .integer,
        NB_TAG_CONST => switch (bits & NB_PAYLOAD_MASK) { ... },
        NB_TAG_CHAR => .char,
        NB_TAG_BUILTIN => .builtin_fn,
        else => unreachable,
    };
}
```

**ホットパス**:
1. `>> 48` (1 op)
2. `< 0xFFF8` 比較 (1 op) → 大半の数値はここで return
3. それ以外は `switch` (コンパイラが jump table 化、O(1))

→ 全体で **数命令** で完了します。どれほど大きなコレクションを扱う
場合でも、型判定コストは一定です。

---

## 8. 設計判断と却下した代替

| 案                                      | 採否 | 理由                                                             |
|-----------------------------------------|------|------------------------------------------------------------------|
| **NaN boxing 1:1 slot mapping**         | ✓   | 32 種を 4×8 で詰め、type check は band 比較 + 3-bit 読み        |
| Tagged Pointer (8-byte align bits 利用) | ✗   | 即値（int / nil 等）が表現できず、別の boxing が要る             |
| Box 構造体 + ポインタ                   | ✗   | 1 値 16-24 bytes、cache locality 最悪。v1 は Phase 35 で乗り換え |
| Wasm GC `(ref any)`                     | ✗   | NaN boxing と競合。WasmGC は v0.2 評価事項 (ROADMAP §14.3)      |
| `extern union`                          | ✗   | tag を別フィールドに置く必要があり、合計 16 bytes                |

ROADMAP §1.4 (Mission), §4.2 (NaN-boxed Value representation), §A6
(file size) と整合。

---

## 9. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout 8b487f9
zig build test
# value.zig 単体のテスト群が通る

# bit pattern を REPL 風に確認
cat <<'EOF' > /tmp/sample.zig
const std = @import("std");
const Value = @import("src/runtime/value.zig").Value;

pub fn main() !void {
    // Zig 0.16: stdout は `std.Io.File` 経由。Writer は `(io, &buf)` を
    // 取るので、ここでは `std.debug.print`（内部で stderr ロックを取って
    // くれる）でビットパターンを観察する。
    inline for ([_]Value{
        .nil_val,
        .true_val,
        .false_val,
        Value.initInteger(42),
        Value.initFloat(3.14),
    }) |v| {
        std.debug.print("0x{X:0>16} → {s}\n", .{ @intFromEnum(v), @tagName(v.tag()) });
    }
}
EOF

git checkout cw-from-scratch    # 戻る
```

---

## 10. 教科書との対比

| 軸            | v1 (`ClojureWasm`)    | v1_ref                 | Clojure JVM          | 本リポ                      |
|---------------|-----------------------|------------------------|----------------------|-----------------------------|
| 採用時期      | Phase 35 後付け       | Phase 1.2 Day 1        | n/a (`Object`)       | Phase 1.2 Day 1             |
| Value サイズ  | 8 bytes               | 8 bytes                | 8 bytes (object ref) | 8 bytes                     |
| 配置          | sharing slots         | 1:1 mapping (32 slots) | n/a                  | 1:1 mapping (32 slots)      |
| 型判定        | switch + discriminant | band + sub             | `instanceof`         | band + sub                  |
| NaN collision | canonical 化済        | canonical 化           | n/a                  | canonical 化 (我々が再発見) |

v1 に引っ張られず本リポジトリの理念で整理した点：
- v1 の **slot-sharing + discriminant** は型判定が遅く、Phase 35 で
  1:1 mapping に乗り換えました。本リポジトリは **Day 1 から 1:1
  mapping** を採用しています。
- v1 では HeapTag の追加が全コードに波及しましたが、本リポジトリ
  では 32 slot を Day 1 から確保しています（変更耐性 ◎）。

---

## 11. Feynman 課題

1. なぜ NaN bit pattern を「タグ付き値の入れ物」として使えるのか。
   1 行で。
2. ヒープアドレスを `>> 3` で圧縮できる前提は何か。1 行で。
3. `initFloat` が canonical NaN への正規化を行っている理由は何か。
   1 行で。

---

## 12. チェックリスト

- [ ] 演習 2.1: top16 から型判定を 5 例こなせた
- [ ] 演習 2.2: `groupOf` / `subOf` をシグネチャだけから書けた
- [ ] 演習 2.3: `encodeHeapPtr` / `decodePtr` をゼロから書き起こせた
- [ ] 演習 2.4: i48 範囲が即答できる
- [ ] 演習 2.5: NaN collision の予測検証ができた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout 8b487f9` の状態で `zig build test` を緑にできた

---

## 次へ

第 3 章: [エラー基盤 — SourceLocation と threadlocal last_error](./0003_error_infrastructure.md)

— ClojureWasm の `P6 (Error quality is non-negotiable)` を Day 1
から有効にする土台です。`<file>:<line>:<col>` をすべてのエラーに
付与する仕組みと、Zig 0.16 の `anyerror!T` の扱い方を掘り下げます。
