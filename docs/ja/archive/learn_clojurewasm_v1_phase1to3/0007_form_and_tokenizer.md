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

Phase 1 のフロントエンドを 2 段で組み立てる章です。**Form** は
Reader が吐き出す AST（タグ付き union）、**Tokenizer** はソース
文字列を Token 列に切り出す状態機械。どちらも `SourceLocation` を
**Day 1 から全 Form / 全 Token に貼る** ことで、ROADMAP §A7
「concurrency and errors are designed in on day 1」を Phase 1 の
うちに実装してしまいます。

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

**観点 1**: Form は **`data` と `location` の単純なペア** です。
union が形を、`location` が出処を保持します。

**観点 2**: `map` は **平坦な `[k1, v1, k2, v2, ...]` slice** です。
Clojure JVM の reader は `IPersistentMap` を即時に構築しますが、本
リポジトリの Form はマップ化しません。マップは Phase 3 で導入する
heap 型であり、Phase 1 で `runtime/value.zig` から切り離すために
平坦なまま運びます。

### なぜ `Value` ではなく `Form` を吐くのか

Reader が直接 `Value`（NaN-boxed u64）を吐けば後段が単純化されそうに
見えますが、本リポジトリは意図して両者を分けています：

| 軸     | `Form`（reader 出力）         | `Value`（runtime 表現） |
|--------|-------------------------------|-------------------------|
| 寿命   | per-eval の node arena        | per-process の GC heap  |
| 中身   | 構文形（list / vector / map） | 実行時の値（NaN-boxed） |
| Symbol | **未解決**（`{ns, name}`）    | 解決済み Var ref        |
| GC     | trace されない                | trace される            |
| 失敗時 | location 付き → `:5:12` 表示 | location は別物         |

**核心**: Form は macroexpansion の前段で必要な情報（symbol の
namespace、map literal かどうかなど）を、**Value 表現に潰すと失われ
てしまうぶんも含めて** 保持します。Clojure JVM が ASM の AST を別に
持っているのと同じ理由です。ROADMAP §4.4 の「dual backend」を前提
にしており、TreeWalk と VM は **同じ Form から出発して別々にコンパイル
します**。

### `pr-str` formatter

`Form.formatPrStr` は `*std.Io.Writer` に書き出します。Zig 0.16 で
`std.io.AnyWriter` は廃止されており、Writer は `*Writer` で受けるのが
新しいイディオムです（`.claude/rules/zig_tips.md`）。

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

特殊 float 値は **Clojure reader の表記** で出力します（`##NaN` /
`##Inf` / `##-Inf`）。`{d}` の単純フォーマットだと小文字の `nan` に
なってしまい、round-trip が壊れます。

### `typeName` と heap 表現の独立性

`Form.typeName` はエラーメッセージのために `FormData` のタグを文字列化
する関数です。**heap 側の `HeapTag`（第 0002 章）とは独立していて**、
構文上の区別だけを返します:

| Form 例                                  | typeName の戻り値                               |
|------------------------------------------|-------------------------------------------------|
| `Form{ .data = .nil }`                   | `"nil"`                                         |
| `Form{ .data = .{ .keyword = ... } }`    | `"keyword"`（`ns` の有無は型名に出ない）        |
| `Form{ .data = .{ .map = &.{} } }`       | `"map"`（heap-side の `hash_map` ではなく構文） |
| `Form{ .data = .{ .float = nan(f64) } }` | `"float"`                                       |

Form 段階では「これは map literal か」だけが分かれば十分で、「実装
として hash_map か array_map か」は heap 側の関心です。この区別を
ぼかさないために 2 系列の名前空間を別々に維持しています。

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

Form の location には **デフォルト値があります**（テストや synthetic
な Form では省略可能）。プロダクション経路では reader が必ず埋めるため、
本番で "unknown" が出てきたら bug のサインです。

### なぜ ROADMAP §A7 を満たすのか

§A7「Concurrency and errors are designed in on day 1」は **「あとで
SourceLocation を全コードに足す = 1,200 箇所の書き直し」を避けよ**
という意味です。v1 は Phase 30 を過ぎてから後付けすることになり、
reader / analyzer / runtime の全関数に `loc: SourceLocation` を追加
する大手術になりました。

本リポは Day 1 から：
- Form が必ず location を持つ（reader が埋める）
- Token が `line / column` を持つ（reader → Form で転写）
- `runtime/error.zig` の `Info` payload にも location

→ Phase 3.1 の error display（§9.5 / 3.1）は、これを **読み出すだけ
で動きます**。

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

テストでは per-test arena（`std.heap.ArenaAllocator`）を使うので
リークは構造的に発生しません。Phase 2 の analyzer は per-eval の
node arena を渡し、評価が終わるたびに `arena.deinit()` で **木全体
を一発で破棄します**。GC は `Value` を trace しますが、Form は heap
に入らないため trace されません。

### Token から SourceLocation へ転写する

Token 側が持つ `line / column` を Form 側の `SourceLocation` に詰め
直すヘルパは、`src/eval/reader.zig` で次の 1 行に集約されています:

```zig
fn locOf(file_name: []const u8, tok: Token) SourceLocation {
    return .{ .file = file_name, .line = tok.line, .column = tok.column };
}
```

`file_name` は caller が所有する `[]const u8` で、Reader 自身は
コピーを取りません（CLI の `-e` 経路ではプロセス全体寿命の string
リテラルです）。Token も Form も「ソースの中の場所」だけを持ち、
ファイル名の所有権は呼び出し側に委ねる、という分担です。

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

`next()` を呼ぶと次の Token を 1 つ返して状態を進めます。EOF 後は
`.eof` を返し続けます（idempotent）。

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

**観点**: Token を作るたびに文字列をコピーすると、数千回の `alloc()`
が発生します。これを避けるため、source の slice 位置だけを覚えておき、
必要なときに `tok.text(source)` で文字列を取り出します。
**source は Token より長く生き続ける必要があります**（CLI の `-e`
経路ではプロセス全体）。

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

**唯一の 2 文字 lookahead** は、`+1` / `-1` を **数値リテラル
として扱うか、シンボル `+` / `-` として扱うか** の判定です（`(- 1 2)`
は減算、`-1` は数値リテラル）。

### Clojure の特殊リテラル

| 構文                     | Token kind            | 備考                             |
|--------------------------|-----------------------|----------------------------------|
| `nil` / `true` / `false` | `.symbol`             | reader が再分類                  |
| `:keyword`               | `.keyword`            | `:foo`, `:my.ns/key`             |
| `\"string\"`             | `.string`             | エスケープは reader 側でデコード |
| `0xFF`（hex int）        | `.integer`            |                                  |
| `1.5e10`（指数）         | `.float`              |                                  |
| `42N` / `42M`            | `.integer` / `.float` | Phase 1 は精度を捨てる           |

`nil` / `true` / `false` を **`.symbol` として返す** のが設計上の
要点です。字句レベルでは「symbol の形をした識別子」として一律に処理
し、意味付けは reader の仕事に回します。これにより tokenizer が短く
保たれ、reader 側でも `eql(u8, "nil", txt)` の 3 行で済みます
（Clojure JVM の LispReader も同じ責務分離になっています）。

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

各段は `while` ループと境界チェックだけで成立します。再帰なし、
バックトラックなし。これが LL(1) の単純さです。

### `#` dispatcher と コメント

Phase 1 のリーダーマクロは 3 種類だけ：

| 入力 | Token kind        | 用途                         |
|------|-------------------|------------------------------|
| `#_` | `.discard`        | 直後の form を捨てる         |
| `##` | `.symbolic`       | `##NaN` / `##Inf` / `##-Inf` |
| `#!` | （行末まで skip） | shebang line                 |

`#"re"`（regex）、`#'`、`#()` などは **Phase 2+ で `readDispatch`
に分岐を追加するだけ** で済む構造になっています（A2: 新機能は
新分岐で）。

Whitespace は標準的な空白文字 + **カンマ**：

```zig
fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '\x0C', ',' => true,  // comma!
        else => false,
    };
}
```

`[1, 2, 3]` も `[1 2 3]` も **同じ Token 列になります**。Clojure
文化の見た目を保ちつつ、reader 側で分岐を増やす必要もありません。

### TokenKind の 16 種

Phase 1 で扱う TokenKind は次の 16 種です:

```zig
pub const TokenKind = enum(u8) {
    lparen, rparen, lbracket, rbracket, lbrace, rbrace,
    integer, float, string, symbol, keyword,
    quote, discard, symbolic, eof, invalid,
};
```

**不正入力**（unterminated string、bare `:`、lone `#X`）はすべて
`.invalid` に集約され、行・列を保ったまま reader に渡ります。EOF
以降は `.eof` を返し続ける idempotent な設計なので、reader 側のループ
終了条件が単純になります（`while (tok.kind != .eof) ...`）。

---

## 4. 設計判断と却下した代替

| 案                                     | 採否 | 理由                                    |
|----------------------------------------|------|-----------------------------------------|
| Form = `data` + `location` の構造体    | ✓   | location を Day 1 で全 Form に貼れる    |
| Form を直接 NaN-boxed Value で表現     | ✗   | macroexpansion で Symbol を保持できない |
| Token に `text: []const u8` を持たせる | ✗   | コピー多発。`start + len` で 0 alloc    |
| LL(1) のみ（+1 / -1 のみ 2 文字）      | ✓   | Phase 1 範囲で十分                      |
| LR / GLR / PEG ライブラリ              | ✗   | 依存追加、P2 (final shape day 1) 違反   |
| `nil/true/false` を専用 Token kind     | ✗   | reader 側 3 行で済むので tokenizer 短く |
| Comma を delimiter として Token 化     | ✗   | Clojure 文化に反する                    |

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

| 軸              | v1 (`engine/reader/`) | v1_ref (`eval/`) | Clojure JVM                 | 本リポ                     |
|-----------------|-----------------------|------------------|-----------------------------|----------------------------|
| Tokenizer 行数  | 795                   | 561              | n/a                         | 448                        |
| Form 行数       | 別管理                | 318              | n/a                         | 255                        |
| Token kinds     | 約 25                 | 約 18            | 約 30                       | 16                         |
| location        | Token のみ            | Token + Form     | LineNumberingPushbackReader | Token + Form + Info        |
| ratio `1/2`     | 対応                  | 対応             | 対応                        | Phase 2+                   |
| regex `#"re"`   | tokenizer 分岐        | tokenizer 分岐   | RegexReader class           | Phase 2+ で `readDispatch` |
| BigInt N suffix | 完全対応              | 一部             | 完全対応                    | suffix 食うが精度捨て      |

引っ張られずに本リポジトリの理念で整理した点：
- v1 は regex / metadata / `#()` を Phase 1 から含めた結果、tokenizer
  が 795 行に膨らんでいました。本リポジトリは **Phase 1 = 必要最小**
  にとどめて 448 行に絞り、機能追加は新しい分岐とテストで済む構造に
  しています（A2）。
- Clojure JVM は Reader と Tokenizer が同じファイルで一体化された
  recursive-descent です。本リポジトリは **2 段に分離して** いるので、
  各段を独立にテストできます。
- v1_ref の Form はほぼ同じ形です。違いは `formatPrStr` の Writer
  引数が `anytype` だった点で、本リポジトリは Zig 0.16 への移行に
  合わせて `*std.Io.Writer` 固定にしています（P10）。

---

## この章で学んだこと

- **Form は「構文」を、Value は「実行時値」を持つ別寿命の表現**。
  Reader が間に Form を挟むことで、symbol の namespace と
  `SourceLocation` を macroexpansion 段階まで失わずに運べる。
- Tokenizer は **`start + len` だけ** を持つ零アロケーション lexer
  で、唯一の 2 文字 lookahead は `+1` / `-1` の数値判定。それ以外は
  純粋な LL(1) で 16 種の TokenKind を吐き分ける。

---

## 次へ

第 0008 章: [Reader と Phase 1 CLI](./0008_reader_and_phase1_cli.md)

— Tokenizer が吐く Token 列を **再帰下降パーサ** で Form の木に
組み立てます。`cljw -e "(+ 1 2)"` で **読んで印字するだけ** の最小
CLI を組み、Phase 1 の exit criterion を満たします。さらに
`bench/quick.sh` で Phase 4-7 の最適化に向けた baseline を取ります。
