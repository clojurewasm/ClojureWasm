---
chapter: 7
commits:
  - 6a09869
  - 615fd46
related-tasks:
  - §9.3 / 1.7
  - §9.3 / 1.8
related-chapters:
  - 0006
  - 0008
date: 2026-04-27
---

# 0007 — Form と Tokenizer

> 対応 task: §9.3 / 1.7–1.8 / 所要時間: 90〜120 分

Phase 1 のフロントエンドを 2 段で組み立てる章。**Form** は Reader が
吐く AST（タグ付き union）、**Tokenizer** はソース文字列を Token 列に
切り出す状態機械。どちらも `SourceLocation` を **Day 1 から全 Form /
全 Token に貼る** ことで、ROADMAP §A7「concurrency and errors are
designed in on day 1」を Phase 1 のうちに実装する。

---

## この章で学ぶこと

- Reader が **`Value` ではなく `Form`** を出す理由 — 寿命と用途が違う
- `Form = data + location` が将来のエラー表示に与える影響（P6）
- **LL(1) ステートマシン** で Clojure リテラルを 1 パスで切り出す方法
- Token が **`start + len`** だけ持つ（生文字列をコピーしない）利点

---

## 1. Form — Reader が吐く AST

`src/eval/form.zig` の核：

```zig
pub const FormData = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []const u8,

    symbol: SymbolRef,
    keyword: SymbolRef,

    list: []const Form,
    vector: []const Form,
    /// Flat k/v pairs: `[k1, v1, k2, v2, ...]`.
    map: []const Form,
};

pub const Form = struct {
    data: FormData,
    location: SourceLocation = .{},
};
```

**観点 1**: Form は **`data` と `location` の単純なペア**。union が
形を、`location` が出処を保持する。

**観点 2**: `map` は **平坦な `[k1, v1, k2, v2, ...]` slice**。
Clojure JVM の reader は `IPersistentMap` を即構築するが、本リポの
Form はマップ化しない。マップは Phase 3 で導入する heap 型であり、
Phase 1 で `runtime/value.zig` から切り離すため平坦なまま運ぶ。

### なぜ `Value` ではなく `Form` を吐くのか

Reader が直接 `Value`（NaN-boxed u64）を吐けば後段は単純化されそうに
見えるが、本リポは意図して分けている：

| 軸 | `Form`（reader 出力） | `Value`（runtime 表現） |
|------|--------|---------|
| 寿命 | per-eval の node arena | per-process の GC heap |
| 中身 | 構文形（list / vector / map） | 実行時の値（NaN-boxed） |
| Symbol | **未解決**（`{ns, name}`） | 解決済み Var ref |
| GC | trace されない | trace される |
| 失敗時 | location 付き → `:5:12` 表示 | location は別物 |

**核**: Form は macroexpansion の前段で必要な情報（symbol の
namespace、map literal かどうか）を **Value 表現に潰すと失われる
ぶん** 保持する。Clojure JVM が ASM の AST を別に持つのと同じ理由。
ROADMAP §4.4 の「dual backend」前提で、TreeWalk と VM は **同じ
Form から始め別々に compile する**。

### `pr-str` formatter

`Form.formatPrStr` は `*std.Io.Writer` に書き出す。Zig 0.16 の
`std.io.AnyWriter` は廃止され、Writer は `*Writer` 固定が新イディオム
（`.claude/rules/zig_tips.md`）。

```zig
pub fn formatPrStr(self: Form, w: *Writer) Writer.Error!void {
    switch (self.data) {
        .nil => try w.writeAll("nil"),
        .float => |f| try formatFloat(w, f),  // ##NaN / ##Inf 対応
        .string => |s| try formatString(w, s),  // \" / \\ / \n エスケープ
        .list => |items| try formatCollection(w, "(", ")", items),
        .map => |items| try formatMapEntries(w, items),
        // ...
    }
}
```

特殊 float 値は **Clojure reader の表記** を出す（`##NaN` / `##Inf`
/ `##-Inf`）。`{d}` の単純フォーマットだと小文字の `nan` になり
round-trip が壊れる。

### 演習 7.1: typeName を予測 (L1)

`src/eval/form.zig` の `typeName` を見ずに、以下の戻り値を予測。

```zig
const f1 = Form{ .data = .nil };
const f2 = Form{ .data = .{ .keyword = .{ .ns = "my", .name = "k" } } };
const f3 = Form{ .data = .{ .map = &.{} } };
const f4 = Form{ .data = .{ .float = std.math.nan(f64) } };
```

Q: `f2.typeName()` の戻り値は？  Q: `f3.typeName()` は `"hash_map"` か
`"map"` か？  Q: `f4.typeName()` は？

<details>
<summary>答え</summary>

| Form | typeName() |
|------|------------|
| f1 | `"nil"` |
| f2 | `"keyword"`（namespace の有無は型名に出ない） |
| f3 | `"map"`（heap-side の `hash_map` ではなく構文上の `map`） |
| f4 | `"float"` |

`typeName` はエラーメッセージ用で、heap 表現の `HeapTag`（第 0002
章）とは独立。

</details>

---

## 2. SourceLocation を Day 1 で貼る

`SourceLocation` は `runtime/error.zig` で定義される **共通型**：

```zig
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    line: u32 = 0,    // 1-based; 0 = unknown
    column: u16 = 0,  // 0-based
};
```

Form の location は **デフォルト値あり**（テストや synthetic Form
で省略可能）。プロダクション経路では reader が必ず埋めるので、本番で
"unknown" が出るのは bug の signal。

### なぜ ROADMAP §A7 を満たすのか

§A7「Concurrency and errors are designed in on day 1」は **「あとで
SourceLocation を全コードに足す = 1,200 箇所の書き直し」を回避する**
という意味。v1 は Phase 30 過ぎに後付けし、reader / analyzer / runtime
の全関数に `loc: SourceLocation` を追加する大手術になった。

本リポは Day 1 から：
- Form が必ず location を持つ（reader が埋める）
- Token が `line / column` を持つ（reader → Form で転写）
- `runtime/error.zig` の `Info` payload にも location

→ Phase 3.1 の error display（§9.5 / 3.1）はこれを **読むだけで動く**。

### Form は arena 寿命

Reader は **caller-supplied allocator** に Form を確保する：

```zig
pub const Reader = struct {
    tokenizer: Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,  // ← caller が決める
    ...
};
```

テストは per-test arena (`std.heap.ArenaAllocator`) を使うのでリーク
不可能。Phase 2 の analyzer は per-eval node arena を渡し、評価が
終わるたびに `arena.deinit()` で **木全体を一発で破棄** する。
GC は `Value` を trace するが、Form は heap に入らないので
trace されない。

### 演習 7.2: locOf を書く (L2)

`Token` から `SourceLocation` を作るヘルパ。

```zig
fn locOf(file_name: []const u8, tok: Token) SourceLocation {
    // ここから書く
}
```

ヒント:
- Token は `line: u32` と `column: u16` を持つ
- 戻り値はデフォルト初期化のフィールド構文で作れる

<details>
<summary>答え</summary>

```zig
fn locOf(file_name: []const u8, tok: Token) SourceLocation {
    return .{ .file = file_name, .line = tok.line, .column = tok.column };
}
```

実物 (`src/eval/reader.zig`) と同じ。Reader は `file_name` を所有
しない（caller の責任）。Token も Form も「ソースの中の場所」だけ
持つ。

</details>

---

## 3. Tokenizer — LL(1) ステートマシン

`src/eval/tokenizer.zig` (448 行) は **再起動可能な lexer**。状態は
4 個：

```zig
pub const Tokenizer = struct {
    source: []const u8,
    pos: u32 = 0,    // 現在のバイト位置
    line: u32 = 1,   // 1-based 行番号
    column: u16 = 0, // 0-based 列番号
};
```

`next()` を呼ぶと次の Token 1 個を返して状態を進める。EOF 後は
`.eof` を返し続ける（idempotent）。

### Token は `start + len` のみ

```zig
pub const Token = struct {
    kind: TokenKind,
    start: u32,
    len: u16,     // u16: 65 KiB token 上限。十分
    line: u32,
    column: u16,

    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start .. self.start + self.len];
    }
};
```

**観点**: Token 生成ごとに文字列をコピーすると数千回の `alloc()`。
それを避けて、source slice を覚え、必要なときだけ `tok.text(source)`
で可視化する。**source は Token より長く生きる必要がある**（CLI の
`-e` 経路ではプロセス全体）。

### 1 文字 lookahead で Phase 1 を切る

Clojure の reader は基本 LL(1) で十分：

```zig
const ch = self.source[self.pos];
switch (ch) {
    '(' => return self.singleChar(.lparen, ...),
    '\'' => return self.singleChar(.quote, ...),
    '"' => return self.readString(...),
    ':' => return self.readKeyword(...),
    '#' => return self.readDispatch(...),  // #_ / ## / #!
    else => {
        if (isDigit(ch)) return self.readNumber(...);
        if ((ch == '+' or ch == '-') and self.pos + 1 < self.source.len
            and isDigit(self.source[self.pos + 1])) {
            return self.readNumber(...);  // ← +1 / -1 で 2 文字 lookahead
        }
        if (isSymbolStart(ch)) return self.readSymbol(...);
        return makeTokenAt(.invalid, ...);
    },
}
```

**唯一の 2 文字 lookahead**: `+1` / `-1` を **数値リテラルか
シンボル `+` / `-` か** の判定（`(- 1 2)` は減算、`-1` は数値）。

### Clojure の特殊リテラル

| 構文 | Token kind | 備考 |
|------|------------|------|
| `nil` / `true` / `false` | `.symbol` | reader が再分類 |
| `:keyword` | `.keyword` | `:foo`, `:my.ns/key` |
| `\"string\"` | `.string` | エスケープは reader 側でデコード |
| `0xFF`（hex int） | `.integer` | |
| `1.5e10`（指数） | `.float` | |
| `42N` / `42M` | `.integer` / `.float` | Phase 1 は精度を捨てる |

`nil` / `true` / `false` を **`.symbol` として返す**のは設計上のキモ。
字句レベルでは「symbol-shaped な識別子」として一律処理し、意味付けは
reader の仕事。これにより tokenizer が短くなり、reader で `eql(u8,
"nil", txt)` の 3 行で済む（Clojure JVM の LispReader も同じ責務分離）。

### 数値の状態機械

`readNumber` は 3 段の決定木：

```
   sign?  ─┬─→  0xHEX        → .integer
           ├─→  digits        → 整数部
                ↓
                .  digits      → .float
                ↓
                e±  digits     → .float
                ↓
                N|M suffix     → reader へ
```

各段は `while` ループ + 境界チェックだけで成立。再帰なし、バック
トラックなし。これが LL(1) の単純さ。

### `#` dispatcher と コメント

Phase 1 のリーダーマクロは 3 種類だけ：

| 入力 | Token kind | 用途 |
|------|-----------|------|
| `#_` | `.discard` | 直後の form を捨てる |
| `##` | `.symbolic` | `##NaN` / `##Inf` / `##-Inf` |
| `#!` | （行末まで skip） | shebang line |

`#"re"` (regex), `#'`, `#()` などは **Phase 2+ で `readDispatch` に
枝追加** で済む構造（A2: 新機能は新分岐で）。

Whitespace は標準的な空白文字 + **カンマ**：

```zig
fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '\x0C', ',' => true,  // comma!
        else => false,
    };
}
```

`[1, 2, 3]` も `[1 2 3]` も **同じ Token 列**。Clojure 文化の見た目を
保ちつつ reader は分岐不要。

### 演習 7.3: 1 ファイル分の Tokenizer をゼロから (L3)

ファイル名と公開 API のみ。

```zig
// File: src/eval/tokenizer.zig
//
// pub const TokenKind = enum(u8) {
//     lparen, rparen, lbracket, rbracket, lbrace, rbrace,
//     integer, float, string, symbol, keyword,
//     quote, discard, symbolic, eof, invalid,
// };
//
// pub const Token = struct {
//     kind: TokenKind, start: u32, len: u16, line: u32, column: u16,
//     pub fn text(self: Token, source: []const u8) []const u8;
// };
//
// pub const Tokenizer = struct {
//     source: []const u8, pos: u32 = 0, line: u32 = 1, column: u16 = 0,
//     pub fn init(source: []const u8) Tokenizer;
//     pub fn next(self: *Tokenizer) Token;
// };
```

要求:
- `(+ 1 2)`, `[1 :a "b"]`, `{:k v}`, `'foo`, `##NaN`, `0xFF`,
  `3.14e10`, `; comment\n42`, `1,2,3` を全て tokenize できる
- 改行で `line` +1、`column` リセット
- 不正入力（unterminated string, bare `:`, lone `#X`）は `.invalid`
- EOF 後は `.eof` を返し続ける（idempotent）

<details>
<summary>答え骨子</summary>

```zig
//! Tokenizer — Clojure source text → token stream.
const std = @import("std");

pub const TokenKind = enum(u8) {
    lparen, rparen, lbracket, rbracket, lbrace, rbrace,
    integer, float, string, symbol, keyword,
    quote, discard, symbolic, eof, invalid,
};

pub const Token = struct {
    kind: TokenKind, start: u32, len: u16, line: u32, column: u16,
    pub fn text(self: Token, source: []const u8) []const u8 {
        return source[self.start .. self.start + self.len];
    }
};

pub const Tokenizer = struct {
    source: []const u8, pos: u32 = 0, line: u32 = 1, column: u16 = 0,

    pub fn init(source: []const u8) Tokenizer {
        return .{ .source = source };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return self.makeEof();
        // ... switch (ch) { '(' => ..., ... }; readNumber / readString /
        // readSymbol / readKeyword / readDispatch を本文どおり
    }
    // helpers: skipWhitespace, advance, makeEof, makeToken, singleChar
};

// character classes: isDigit, isHexDigit, isWhitespace (with comma),
// isSymbolChar, isSymbolStart
```

検証: `bash test/run_all.sh` で `tokenizer.zig` の 13 個の test ブロック
が緑になる。

</details>

---

## 4. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| Form = `data` + `location` の構造体 | ✓ | location を Day 1 で全 Form に貼れる |
| Form を直接 NaN-boxed Value で表現 | ✗ | macroexpansion で Symbol を保持できない |
| Token に `text: []const u8` を持たせる | ✗ | コピー多発。`start + len` で 0 alloc |
| LL(1) のみ（+1 / -1 のみ 2 文字） | ✓ | Phase 1 範囲で十分 |
| LR / GLR / PEG ライブラリ | ✗ | 依存追加、P2 (final shape day 1) 違反 |
| `nil/true/false` を専用 Token kind | ✗ | reader 側 3 行で済むので tokenizer 短く |
| Comma を delimiter として Token 化 | ✗ | Clojure 文化に反する |

ROADMAP §A6（一ファイル ≤ 1000 行）：tokenizer 448 行 + form 255
行 = 703 行で 2 ファイル。v1 の `engine/reader/`（795 + 1602 = 2397
行）から **約 70% 削減**。
ROADMAP §A7（errors designed in day 1）：全 Form / Token に line/col。

---

## 5. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

git checkout 6a09869
zig build test 2>&1 | grep -E "(form|FAIL)"
# → form.zig 内の 8 個の test が緑

git checkout 615fd46
zig build test 2>&1 | grep -E "(tokenizer|FAIL)"
# → tokenizer.zig 内の 13 個の test が緑

git checkout cw-from-scratch
bash test/run_all.sh   # 全 suite 緑
```

---

## 6. 教科書との対比

| 軸 | v1 (`engine/reader/`) | v1_ref (`eval/`) | Clojure JVM | 本リポ |
|------|--------|---------|-------------|---------|
| Tokenizer 行数 | 795 | 561 | n/a | 448 |
| Form 行数 | 別管理 | 318 | n/a | 255 |
| Token kinds | 約 25 | 約 18 | 約 30 | 16 |
| location | Token のみ | Token + Form | LineNumberingPushbackReader | Token + Form + Info |
| ratio `1/2` | 対応 | 対応 | 対応 | Phase 2+ |
| regex `#"re"` | tokenizer 分岐 | tokenizer 分岐 | RegexReader class | Phase 2+ で `readDispatch` |
| BigInt N suffix | 完全対応 | 一部 | 完全対応 | suffix 食うが精度捨て |

引っ張られず本リポの理念で整理した点：
- v1 は regex / metadata / `#()` を Phase 1 から含めて 795 行膨らんだ。
  本リポは **Phase 1 = 必要最小** で 448 行に絞り、追加は新分岐 +
  テストで済む構造（A2）。
- Clojure JVM は Reader と Tokenizer が同じファイルで一体化される
  recursive-descent。本リポは **2 段分離** で各段を独立に test できる。
- v1_ref の Form はほぼ同形。違いは `formatPrStr` の Writer 引数が
  `anytype` だった点。本リポは Zig 0.16 移行で `*std.Io.Writer` 固定
  (P10)。

---

## 7. Feynman 課題

6 歳の自分に説明するつもりで答える。

1. なぜ Reader は **`Form` を出して `Value` を出さない** のか？ 1 行で。
2. Token が **`text` フィールドではなく `start + len`** を持つ利点は？
   1 行で。
3. `nil` / `true` / `false` が **`.symbol` token** として返るのは
   なぜ？ 1 行で。

---

## 8. チェックリスト

- [ ] 演習 7.1: 4 つの Form の `typeName()` を即答できた
- [ ] 演習 7.2: `locOf` を 3 行で書けた
- [ ] 演習 7.3: Tokenizer の 16 種 TokenKind と `next()` dispatch を
  シグネチャだけから再構成できた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout 6a09869` と `git checkout 615fd46` の状態で個別
  test を緑にできた

---

## 次へ

第 0008 章: [Reader と Phase 1 CLI](./0008-reader-and-phase1-cli.md)

— Tokenizer が吐く Token 列を **再帰下降パーサ** で Form の木に組み
立てる。`cljw -e "(+ 1 2)"` が **読んで印字するだけ** の最小 CLI を
組み、Phase 1 の exit criterion を満たす。さらに `bench/quick.sh` で
Phase 4-7 の最適化に向けた baseline を取る。
