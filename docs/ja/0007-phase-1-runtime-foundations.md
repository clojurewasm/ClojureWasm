---
commits:
  - 8b487f9
  - 61ccbf8
  - c22f900
  - 902e22d
  - 1825f24
  - b60924b
  - 6a09869
  - 615fd46
  - b6efa7f
  - eead562
  - 04476ac
date: 2026-04-26
scope:
  - src/runtime/value.zig
  - src/runtime/error.zig
  - src/runtime/gc/arena.zig
  - src/runtime/collection/list.zig
  - src/runtime/hash.zig
  - src/runtime/keyword.zig
  - src/eval/form.zig
  - src/eval/tokenizer.zig
  - src/eval/reader.zig
  - src/main.zig
  - bench/quick.sh
related:
  - ROADMAP §4.2 (NaN boxing)
  - ROADMAP §9.3 (Phase-1 task list 1.1–1.12)
  - 原則 P2 (final shape on day 1) / P9 (one task = one commit)
---

# 0007 — Phase 1: ランタイム基盤と Reader/Printer の往復

## 背景 (Background)

Phase 1 の目標は **「テキストを読み取り、Form として印字して戻せる」**
最小ループを、最終形のディレクトリレイアウト（ROADMAP §5）に乗せて
構築すること。Exit criterion は `cljw -e "(+ 1 2)"` がそのまま
`(+ 1 2)` を返すこと。**評価器はまだない**ので、Phase 1 が出荷する
のは "read–print" 往復であって、"read–eval–print" ではない。

ここで押さえる処理系理論：

- **NaN boxing**: IEEE-754 倍精度の NaN ビット領域に整数 / ポインタ
  などを忍び込ませ、すべての Value を `u64` 1 個 (8 バイト) に
  納める手法。Clojure の `Object` ヒープに比べて、cache miss を
  避けつつ多態的な値表現を保つために有効。CW v1 がこの設計を
  採用しており、本リライトもこれを踏襲する。
- **Persistent list (cons cell)**: 不変リスト。`cons(x, ys)` は
  `ys` をそのまま再利用する **structural sharing** で実装され、
  prepend が O(1) になる。`count` を各セルに precompute しておく
  ことで `(count xs)` も O(1)。
- **Murmur3 hash**: Clojure JVM の `clojure.lang.Murmur3` を移植。
  `int` 演算が JVM 側で wrap (overflow) するので、Zig でも `*%` /
  `+%` を使って **wrapping arithmetic** を貫く必要がある。これを
  守らないと値の hash が JVM と一致しなくなり、`hash` が
  observable に違ってしまう。
- **Recursive-descent reader**: トークン列を `Form` 木に畳む素朴な
  再帰下降。`max_depth` で再帰ガードしておき、`((((...` のような
  入力でスタックを吹き飛ばさない。

Zig 0.16 のイディオム：

- `std.io.AnyWriter` は廃止。`*std.Io.Writer` が唯一のライタ
  インタフェース。fixed buffer 用には `Writer.fixed(&buf)` と
  `w.buffered()`、allocating には `Writer.Allocating`。
- `std.Thread.Mutex` は削除。`std.Io.Mutex.lock(io)` か
  `std.atomic.Mutex` を使う。Phase 1 はシングルスレッドなので
  そもそも mutex を持たない。
- `extern struct` で C ABI 互換、`packed struct(<width>)` で
  ビット精密レイアウト。`HeapHeader` は両方の組み合わせ。
- `enum(u64)` を Value に使うことで、`@intFromEnum` /
  `@enumFromInt` で u64 ⇄ Value を bit-level で自由に往復できる。
  さらに `nil_val` / `true_val` / `false_val` だけは具象
  バリアントとして書いておくと、テストや初期化が `const v: Value =
  .nil_val;` だけで済む（`switch` を経由する必要がない）。

Clojure 仕様の関連箇所：

- Reader macros の `'` (quote)、`##Inf` / `##-Inf` / `##NaN`
  (symbolic float)、`#_` (form discard)、`#!` (shebang skip)。
  Phase 1 はこの最小集合のみ。`` ` `` / `~` / `~@` / `^` / `#()` /
  `#'` / `#"re"` / `#inst` / `#uuid` は後フェーズに送る。
- `nil` / `true` / `false` は **lexer ではなく reader** で再分類
  される（lexer はすべて `symbol` トークンを吐く）。これは
  Clojure spec と一致した設計判断。

## やったこと (What)

11 コミット。Layer 0（runtime）→ Layer 1（eval）→ Layer 3（app）と
**ボトムアップ**に積み、最後にベンチハーネスで Phase 1 ベースライン
を凍結している。

### 8b487f9 — feat(runtime): add NaN-boxed Value with HeapTag and HeapHeader

- 新規: `src/runtime/value.zig` (337 行)
- 編集: `src/main.zig` (テスト発見のため `_ = @import(...)`)

`Value = enum(u64)` を中心に `HeapTag` (32 slot) と `HeapHeader`
(`extern struct { tag: u8, flags: packed struct(u8) }`) を実装。
top16 のバンド配置を ROADMAP §4.2 に厳密に揃え、`isHeap` /
`isImmediate` がそれぞれ単一の bit-mask 比較になる。

### 61ccbf8 — feat(runtime): add error infrastructure

- 新規: `src/runtime/error.zig` (424 行)

`SourceLocation`、12 バリアントの `Kind` (Zig `Error` タグと 1:1)、
`Phase` 区分、threadlocal `last_error` / `call_stack` (64 frame)、
`expect{Number,Integer,Boolean}` / `checkArity{,Min,Range}` ヘルパー、
そして Phase-1 用の `BuiltinFn = *const fn ([]const Value,
SourceLocation) Error!Value`。Zig は error union にペイロードを
載せられないので、構造化エラーを threadlocal で運ぶのが定石。

### c22f900 — feat(runtime): add Phase-1 ArenaGc

- 新規: `src/runtime/gc/arena.zig` (201 行)

アリーナ GC。`std.mem.Allocator` ビューを返しつつ
`bytes_allocated` / `alloc_count` を `Stats` に積む。Day-1 の
将来予約として `suppress_count` (マクロ展開中の collect 抑止) と
`gc_stress` の comptime フラグを置いた。

### 902e22d — feat(runtime): add PersistentList cons cell

- 新規: `src/runtime/collection/list.zig` (174 行)

`Cons` セル (header + first + rest + meta + count) と `cons` /
`first` / `rest` / `countOf` / `seq`。`count` を precompute する
ことで O(1) 長さ。`first(.nil_val) = nil` を返すなど Clojure の
nil-tolerant な seq 規約に従う。

### 1825f24 — feat(runtime): add Murmur3 hash

- 新規: `src/runtime/hash.zig` (180 行)

`hashInt` / `hashLong` / `hashString` と、コレクション用の
`mixCollHash` / `hashOrdered` / `hashUnordered`。すべて `*%` /
`+%` で wrapping。string は **UTF-8 バイトを直接ハッシュ** する
（JVM は UTF-16 code unit）— Wasm/edge を主戦場にする方針との整合
を取った v1 の判断を継承。

### b60924b — feat(runtime): add Phase-1 KeywordInterner

- 新規: `src/runtime/keyword.zig` (228 行)

シングルスレッド前提の interner。`(ns, name)` が同一なら
ポインタ等価な Value が返るので、equality が u64 比較に潰れる。
Phase 2.0 が `*Runtime` 引数 + `std.Io.Mutex` を被せて再公開する
予定。**セルレイアウト** (header + ns + name + hash_cache) は
今この時点で凍結したので、Phase 2.0 の差分は呼び出し側のみ。

### 6a09869 — feat(eval): add Form AST with SourceLocation

- 新規: `src/eval/form.zig` (256 行)

reader が産む AST。`SourceLocation` を runtime layer から
**再利用** することで、parse-time と eval-time のエラー座標が
最初から一致する。map は `[k0 v0 k1 v1 ...]` の flat 配列で
持ち、analyzer の繰り返しが楽になる。`formatPrStr` は
`*std.Io.Writer` を取り、`toString` は `Writer.Allocating`
でラップ。`##NaN` / `##Inf` / `##-Inf` を Clojure の reader 出力
と一致させた。

### 615fd46 — feat(eval): add Phase-1 Tokenizer

- 新規: `src/eval/tokenizer.zig` (449 行)

ステートフルな lexer。`Token` が `start` / `len` を持って
source slice を直接スライスするので、コピーを作らない。コンマは
whitespace、行コメント (`;`) と `#!` shebang は透明にスキップ。
`nil` / `true` / `false` はあえて `symbol` として吐き、reader が
再分類する。

### b6efa7f — feat(eval): add Phase-1 Reader

- 新規: `src/eval/reader.zig` (435 行)

トークン列 → `Form`。原子・list / vector / map・reader macros
(`'`, `##`, `#_`) を扱う。`max_depth = 1024` でガード。
`(0xFF` の N サフィックス、`1.5M` の M サフィックスは構文として
受けるが Phase 1 では精度を保持しない (`std.fmt.parseInt` /
`parseFloat` に投げる前にストリップ)。

### eead562 — feat(app): wire Reader into the cljw CLI

- 編集: `src/main.zig`

`-e <expr>` / `--eval <expr>` フラグを実装。引数なしなら従来の
"ClojureWasm" 表示、`-e` ありなら top-level form を `Reader.read`
で順次読み、`Form.formatPrStr` で stdout に書き戻す。
**評価はしない** — Phase 1 が出荷するのは round-trip だけ。

### 04476ac — bench(infra): add Phase-1 quick.sh harness

- 新規: `bench/quick.sh` / `bench/quick_baseline.txt`

ReleaseFast バイナリに対して 3 計測 (cold start / `-e "(+ 1 2)"`
/ 100-form read) と バイナリサイズを記録。`fib_recursive` /
`arith_loop` / `list_build` などは eval が必要なので Phase 4+ で
追記する `TODO(phase4)` プレースホルダ。

## コード (Snapshot)

### Value の top16 バンド (`src/runtime/value.zig`, commit 8b487f9)

```zig
// Heap groups (contiguous: 0xFFF8-0xFFFB)
const NB_HEAP_TAG_A: u64 = 0xFFF8_0000_0000_0000;  // string..hash_set
const NB_HEAP_TAG_B: u64 = 0xFFF9_0000_0000_0000;  // fn_val..regex
const NB_HEAP_TAG_C: u64 = 0xFFFA_0000_0000_0000;  // lazy_seq..volatile
const NB_HEAP_TAG_D: u64 = 0xFFFB_0000_0000_0000;  // transient_vector..class

// Immediate types (contiguous: 0xFFFC-0xFFFF)
const NB_INT_TAG: u64 = 0xFFFC_0000_0000_0000;
const NB_CONST_TAG: u64 = 0xFFFD_0000_0000_0000;   // nil(0) / true(1) / false(2)
const NB_CHAR_TAG: u64 = 0xFFFE_0000_0000_0000;
const NB_BUILTIN_FN_TAG: u64 = 0xFFFF_0000_0000_0000;
```

### `tag()` のディスパッチ

```zig
pub fn tag(self: Value) Tag {
    const bits = @intFromEnum(self);
    const top16: u16 = @truncate(bits >> NB_TAG_SHIFT);
    if (top16 < NB_FLOAT_TAG_BOUNDARY) return .float;
    const sub: u8 = @truncate((bits >> NB_HEAP_SUBTYPE_SHIFT) & NB_HEAP_SUBTYPE_MASK);
    return switch (top16) {
        NB_TAG_A => heapTagToTag(sub),
        NB_TAG_B => heapTagToTag(sub + NB_HEAP_GROUP_SIZE),
        NB_TAG_C => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 2),
        NB_TAG_D => heapTagToTag(sub + NB_HEAP_GROUP_SIZE * 3),
        NB_TAG_INT => .integer,
        NB_TAG_CONST => switch (bits & NB_PAYLOAD_MASK) {
            0 => .nil, 1, 2 => .boolean, else => unreachable,
        },
        NB_TAG_CHAR => .char,
        NB_TAG_BUILTIN => .builtin_fn,
        else => unreachable,
    };
}
```

### Reader の round-trip (`cljw -e "(+ 1 2)"`)

```zig
// src/main.zig
var reader = Reader.init(arena, expr.?);
while (true) {
    const form = try reader.read() orelse break;
    try form.formatPrStr(stdout);
    try stdout.writeByte('\n');
}
```

## なぜ (Why)

**設計判断と却下した代替**

- 代替 A: Value を tagged union (`union(enum)`) で書く。
  却下: Clojure の値は最も hot なオブジェクト。タグの discriminant
  に毎回 1 byte 払うのは binary size と cache 効率に響く。NaN boxing
  なら判別もペイロードもまとめて u64 1 個で済む。

- 代替 B: HeapTag を `u5` (32 値だけ) にして packed struct で詰める。
  却下: `extern struct` のメンバとして `enum(u8)` を置く方が ABI が
  読みやすい。1 バイト節約しても heap object 自体が 24+ バイトある
  ので影響なし。

- 代替 C: KeywordInterner を最初から `*Runtime` 引数で書く。
  却下: Phase 1 は Runtime がまだ存在しない。Phase 2.0 で `*Runtime`
  を渡す前提にすると、それまでの 1 phase ぶんビルドが通らない。
  「セルレイアウトだけ凍結」が P2 (final shape on day 1) と
  互換性のあるバランス。

- 代替 D: Form と Token を別の `SourceLocation` 型で持つ。
  却下: parse-time と eval-time のエラーが座標を共有できないと、
  ROADMAP §4 / 原則 P6 (Error quality is non-negotiable) に反する。
  Form は `runtime/error.zig` の `SourceLocation` を直接 import。

**ROADMAP / 原則への対応**

- §4.2 (NaN boxing) — 完全準拠。slot 配置は表通り。
- §4.7 (GC subsystem) — Phase 1 は arena のみ。Phase 5 で mark-sweep。
- §4.8 (Memory tiers) — node arena / GC alloc の役割分担を tokenizer
  と reader が暗黙に守る (どちらも arena に書くだけ)。
- 原則 P2 — Phase 1 のうちにレイアウトを `runtime/{value, error, gc/,
  collection/, keyword, hash}.zig` + `eval/{form, tokenizer, reader}
  .zig` で固定。
- 原則 P9 — 1 タスク = 1 コミットを 11 タスク全てで保持。

## 確認 (Try it)

```sh
git checkout 04476ac
zig build
./zig-out/bin/cljw                       # → ClojureWasm
./zig-out/bin/cljw -e "(+ 1 2)"          # → (+ 1 2)
./zig-out/bin/cljw -e '1 :foo "bar" [1 2 3] {:a 1}'
# →
# 1
# :foo
# "bar"
# [1 2 3]
# {:a 1}

bash test/run_all.sh                     # 94/94 tests + zone_check OK

# x86_64 gate (1.12)
orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'
```

## 学び (Takeaway)

**処理系一般**

- NaN boxing は単一の `u64` だけで多態を表現する強力な手段だが、
  「f64 の負号 NaN ビット列」と「ヒープタグ」が衝突する箇所
  (`top16 >= 0xFFF8` の負号 NaN) を canonical positive NaN に
  正規化する一手間が要る。これを忘れると `(NaN == NaN)` の比較で
  突然 `string` タグの偽 Value が現れる。
- Lexer と Reader の責務分割は重要：「`nil` / `true` / `false` は
  lexer ではなく reader で再分類する」を最初から守らないと、後で
  `nil?` のような述語の実装でレイヤーをまたぐ穴が残る。

**Zig 0.16**

- `enum(u64)` + `_,` (open enum) パターンは tagged union よりも
  bit-level で軽い。`@intFromEnum` / `@enumFromInt` で u64 ⇔ enum
  をゼロコストで往復できる。
- `std.io.AnyWriter` 廃止 → `*std.Io.Writer` 一本化。`Writer.fixed(&buf)`
  と `Writer.Allocating` は 0.15 までの `fixedBufferStream` /
  `ArrayList(u8).writer().any()` の素直な置き換え。
- `std.Thread.Mutex` も廃止。Phase 1 のように本当に並行が要らない
  期間は **mutex を半分書きにせず、まったく持たない** のが安全。

**Clojure**

- `hash` は JVM の `int` overflow 仕様（wrap）に依存しているので、
  Zig 側でも `*%` / `+%` で同じ wrap 挙動を再現しないと
  observable な値が変わる。
- Reader macros の最小集合 (`'`, `##`, `#_`, `#!`) だけでも
  `(+ 1 2)` から `##Inf` まで一通りの round-trip が成立する。
  syntax-quote / unquote は macro expansion が要るので Phase 2+。

**プロジェクト運用**

- v1_ref を見ながら "実証済みデザインを移植" する形を取れたので、
  11 タスクが TDD として大きく赤くなる場面はほぼなかった。
  これは Phase 2 の analyzer / TreeWalk では再現しづらい (Phase 1
  はレイアウト固定が主目的だった)。次の phase からは設計判断が
  もっと尖るので、TDD の "Red" がまともに赤くなる練習場になる。
