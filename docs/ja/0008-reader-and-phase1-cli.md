---
chapter: 8
commits:
  - b6efa7f
  - eead562
  - 04476ac
related-tasks:
  - §9.3 / 1.9
  - §9.3 / 1.10
  - §9.3 / 1.11
  - §9.3 / 1.12
related-chapters:
  - 0007
  - 0009
date: 2026-04-27
---

# 0008 — Reader と Phase 1 CLI

> 対応 task: §9.3 / 1.9–1.12 / 所要時間: 90〜120 分

Phase 1 の閉じ。**Reader** は Token 列を **再帰下降** で Form 木に
組み立て、**最小 CLI** (`cljw -e "(+ 1 2)"`) は Reader の出力を Form
formatter で印字するだけの **Read-Print 往復** を成立させる。さらに
**`bench/quick.sh`** で Phase 4-7 最適化に向けた baseline を記録し、
最後に **x86_64 cross-arch gate** で Phase 1 を閉じる。

---

## この章で学ぶこと

- 再帰下降が Token kind だけを見て list / vector / map をネストする
  仕組み
- `read()` が **`?Form`** を返す理由 — null = clean EOF と error の区別
- Phase 1 の exit criterion: **eval 抜きで Read + Print 往復** (P9)
- **Juicy Main**: `pub fn main(init: std.process.Init)` から io / arena
  / args を一括取得する Zig 0.16 慣習
- **early baseline** の哲学: Phase 1 で計測値を残せば Phase 4-7 の
  最適化効果を数値で説明できる

---

## 1. Reader — 再帰下降パーサ

`src/eval/reader.zig` (434 行) の核：

```zig
pub const Reader = struct {
    tokenizer: Tokenizer,
    source: []const u8,
    allocator: std.mem.Allocator,
    peeked: ?Token = null,        // 1-token lookahead
    depth: u32 = 0,
    max_depth: u32 = 1024,         // 再帰スタック保護
    file_name: []const u8 = "unknown",
    ...
};
```

### `read()` が `?Form` を返す理由

```zig
/// Read one Form. Returns `null` on clean EOF.
pub fn read(self: *Reader) ReadError!?Form {
    const tok = self.nextToken();
    if (tok.kind == .eof) return null;
    return try self.readForm(tok);
}
```

戻り値は **`!?Form`**：

| 戻り値 | 意味 |
|--------|------|
| `Form` | 1 個読めた。続けて呼べる |
| `null` | クリーンな EOF。**もう読むものがない** |
| `error.SyntaxError` 等 | 入力が壊れている |

`Form` だけを返す API（EOF も Form で表現）にすると caller が毎回
条件分岐を書く羽目になる。Zig の `?T` を使えば `while ((try
reader.read()) |form| { ... }` という Zig らしい形になる。

### `readForm` の dispatch

Token kind 1 個で 11 種類の Form 型のどれを作るか決まる：

```zig
fn readForm(self: *Reader, tok: Token) ReadError!Form {
    return switch (tok.kind) {
        .symbol => self.readSymbol(tok),
        .integer => self.readInteger(tok),
        .float => self.readFloat(tok),
        .string => self.readString(tok),
        .keyword => self.readKeyword(tok),
        .lparen => self.readList(tok),
        .lbracket => self.readVector(tok),
        .lbrace => self.readMap(tok),
        .quote => self.readQuote(tok),
        .symbolic => self.readSymbolic(tok),
        .discard => self.readDiscard(tok),
        .rparen, .rbracket, .rbrace, .eof, .invalid => error.SyntaxError,
    };
}
```

`rparen` / `rbracket` / `rbrace` がここで syntax-error になるのは、
**それらは `readDelimited` の中でのみ正当**だから。top-level で `)`
が来たら未対応の `(` がない = 不正。

### `nil` / `true` / `false` の再分類

第 0007 章で「tokenizer は識別子と区別しない」と書いた件の続き。
3 行の `eql` 比較で済む：

```zig
fn readSymbol(self: *Reader, tok: Token) ReadError!Form {
    const txt = tok.text(self.source);
    const loc = self.locOf(tok);
    if (std.mem.eql(u8, txt, "nil"))   return Form{ .data = .nil,                  .location = loc };
    if (std.mem.eql(u8, txt, "true"))  return Form{ .data = .{ .boolean = true },  .location = loc };
    if (std.mem.eql(u8, txt, "false")) return Form{ .data = .{ .boolean = false }, .location = loc };
    return Form{ .data = .{ .symbol = parseSymbolRef(txt) }, .location = loc };
}
```

### コレクションの再帰下降

list / vector / map は共通の `readDelimited` で組む：

```zig
fn readDelimited(self: *Reader, closing: TokenKind) ReadError![]const Form {
    self.depth += 1;
    if (self.depth > self.max_depth) return error.SyntaxError;
    defer self.depth -= 1;

    var items: std.ArrayList(Form) = .empty;
    errdefer items.deinit(self.allocator);

    while (true) {
        const tok = self.nextToken();
        if (tok.kind == .eof) return error.SyntaxError;   // 未対応 (
        if (tok.kind == closing) break;
        const f = try self.readForm(tok);
        items.append(self.allocator, f) catch return error.OutOfMemory;
    }
    return items.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
}
```

3 つのキモ:

1. **`depth` ガード**: `((((((((((...` で再帰スタックが爆発するのを
   1024 で止める（攻撃面を塞ぐ）。
2. **`errdefer items.deinit(...)`**: 途中エラーで Form 配列を解放
   してから抜ける。Zig 0.16 の `.empty` + per-call allocator イディオム。
3. **map は偶数長を要求**: `{:a 1 :b}` は reader レベルで
   syntax-error にする。これにより analyzer は `[k0 v0 k1 v1 ...]` を
   再チェックなしで反復できる。

```zig
fn readMap(self: *Reader, tok: Token) ReadError!Form {
    const items = try self.readDelimited(.rbrace);
    if (items.len % 2 != 0) return error.SyntaxError;
    return Form{ .data = .{ .map = items }, .location = self.locOf(tok) };
}
```

### syntax-quote を Phase 1 で扱わない理由

Clojure の syntax-quote (`` `(+ ~x ~@ys) ``) は強力だが、Phase 1 では
扱わない。理由は **P3 (core stays stable)** と **P9 (1 commit = 1
task)** を満たすため：

- syntax-quote は **Form → Form 変換** として Phase 2+ で実装する
  （`expandSyntaxQuote` 関数）。Reader の責務は **生 Token → Form 木**。
- Phase 1 で扱う `'` (quote) は **「次の form を `(quote x)` に包む」**
  だけの 1 行展開で、symbol 解決を伴わない：

```zig
fn readQuote(self: *Reader, tok: Token) ReadError!Form {
    // ... depth guard ...
    const inner = try self.readForm(self.nextToken());
    const items = self.allocator.alloc(Form, 2) catch return error.OutOfMemory;
    items[0] = Form{ .data = .{ .symbol = .{ .name = "quote" } }, .location = loc };
    items[1] = inner;
    return Form{ .data = .{ .list = items }, .location = loc };
}
```

`'foo` → `(quote foo)` という形だけの変換。`quote` を special form と
して意味付けるのは analyzer の仕事。

### 文字列のエスケープデコード

Tokenizer は文字列を生のまま（`"hello\\nworld"` のリテラル 7 バイト）
で渡す。Reader が `\n` / `\t` / `\uXXXX` をデコードする：

```zig
fn unescapeString(self: *Reader, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;  // ← fast path
    // ...本格パスは ArrayList へバイトを書き出し
}
```

**fast path**: ソースに `\` が 1 個もない場合は **alloc 一切なし**。
大半の文字列（変数名、UI 文字列）で勝つ最適化。

### 演習 8.1: read の戻り値を予測 (L1)

```zig
var r = Reader.init(arena, INPUT);
const x = try r.read();    // 1 回目
const y = try r.read();    // 2 回目
```

| INPUT | x | y |
|-------|---|---|
| `""` | ? | ? |
| `"42"` | ? | ? |
| `"42 99"` | ? | ? |
| `"#_skip 42"` | ? | ? |

<details>
<summary>答え</summary>

| INPUT | x | y |
|-------|---|---|
| `""` | `null` | `null` |
| `"42"` | `Form{integer=42}` | `null` |
| `"42 99"` | `Form{integer=42}` | `Form{integer=99}` |
| `"#_skip 42"` | `Form{integer=42}` | `null` |

`#_` は次の form を捨てるので `42` だけ返す。`#_` だけで終わる入力
（`"#_"`）は `error.SyntaxError`。

</details>

---

## 2. Minimal CLI — Read + Print

`src/main.zig` は Phase 1.10 (commit `eead562`) 時点で **eval 抜き**。
Phase 2 で analyzer + tree-walk が刺さって RAEP に拡張される。

### Phase 1.10 時点の main.zig

```zig
//! `cljw` entry point (Phase 1).
//! - With no arguments, prints `ClojureWasm` (smoke output).
//! - With `-e <expr>`, reads each top-level form and prints it back
//!   through `Form.formatPrStr`. **No evaluation yet** — Phase 2
//!   wires the analyzer + tree-walk backend.

const std = @import("std");
const Reader = @import("eval/reader.zig").Reader;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    // ... stderr 同様
    // ... -e / -h flag parse ...

    if (expr == null) {
        try stdout.writeAll("ClojureWasm\n");
        try stdout.flush();
        return;
    }

    var reader = Reader.init(arena, expr.?);
    while (true) {
        const form_opt = reader.read() catch |err| {
            try stderr.print("Read error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        const form = form_opt orelse break;
        try form.formatPrStr(stdout);
        try stdout.writeByte('\n');
    }
    try stdout.flush();
}
```

### Juicy Main イディオム

`std.process.Init` は Zig 0.16 の **「main 引数バンドル」**：

| フィールド | 中身 |
|------------|------|
| `init.io` | `std.Io` DI 値 — 全 I/O 操作の基盤 |
| `init.gpa` | thread-safe GPA — runtime / heap 用 |
| `init.arena` | process-lifetime arena — 一過性の alloc に |
| `init.minimal.args` | argv iterator |
| `init.environ_map` | env vars |
| `init.preopens` | WASI の preopened FDs |

`argc` / `argv` を自前で扱うコードは Zig 0.16 では書かない。
`init.minimal.args.iterate()` が WASI / Linux / macOS / Windows で統一
API を出す。これは P10（Honour Zig 0.16 idioms）の典型例。

### Stdout の書き方 — 3 つのキモ

```zig
var stdout_buf: [4096]u8 = undefined;
var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
const stdout = &stdout_writer.interface;

try stdout.print("hello {s}\n", .{"world"});
try stdout.flush();   // ← 忘れがち。バッファ flush しないと出ない
```

1. buffer は stack 上で確保（`[4096]u8 = undefined`）。heap alloc 不要
2. `std.Io.File.stdout().writer(io, &buf)` で `File.Writer` を返す
3. `.interface` フィールドで `*std.Io.Writer` に降ろす — これが
   `Form.formatPrStr` に渡せる型

`std.io.AnyWriter` も `std.io.fixedBufferStream` も Zig 0.16 で削除済み。

### Phase 1 の exit criterion

ROADMAP §9.3 / 1.10:

```
| 1.10 | src/main.zig — minimal CLI with -e flag; reads + prints (no eval yet) | [x] |
```

「**eval なし**」が明記されている。Phase 1 は **「Read + Print の
往復」だけ** を exit criterion にする。これは P9（1 commit = 1 task）
を反映：analyzer / tree-walk / primitive 登録は Phase 2 で別 commit に
する。

### 動作確認

```sh
$ ./zig-out/bin/cljw
ClojureWasm

$ ./zig-out/bin/cljw -e "(+ 1 2)"
(+ 1 2)

$ ./zig-out/bin/cljw -e "42 \"hello\" :foo"
42
"hello"
:foo

$ ./zig-out/bin/cljw -e "(("
Read error: SyntaxError
```

`(+ 1 2)` を入れて `(+ 1 2)` がそのまま出る = **eval せず Read + Print
のみ**。

### 演習 8.2: argv handling (L2)

シグネチャだけ与えるので、本体を書いてください。

```zig
const ArgsResult = union(enum) {
    show_smoke,
    show_help,
    eval_expr: [:0]const u8,
    error: []const u8,
};

fn parseArgs(args: *std.process.ArgIterator) ArgsResult {
    // ここから書く。argv[0] は捨てる前提
}
```

ヒント:
- `args.skip()` で argv[0] を捨てる
- `std.mem.eql(u8, arg, "-e")` で flag マッチ
- `-e` の後ろに引数がないときは `.error`

<details>
<summary>答え</summary>

```zig
fn parseArgs(args: *std.process.ArgIterator) ArgsResult {
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--eval")) {
            const next = args.next() orelse return .{ .error = "-e requires arg" };
            return .{ .eval_expr = next };
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .show_help;
        } else {
            return .{ .error = "unknown option" };
        }
    }
    return .show_smoke;
}
```

実装と少し違うが観察可能挙動は同じ（P11 observable semantics
compatibility）。

</details>

---

## 3. bench/quick.sh — 早すぎる baseline?

`bench/quick.sh`（commit `04476ac`）は Phase 1 で **何も最適化していない
状態の数値** を記録する。目的は ROADMAP §10.2:

> Mid-phase quick bench (4-7): Before the full Phase-8 harness, a
> `bench/quick.sh` covering 5–6 microbenchmarks goes in just before
> Phase 4. Used during Phases 4-7.

本番 baseline (`bench/history.yaml`) は **Phase 8 で固定** する
（§10.1）。それまでの Phase 4-7 の最適化が「悪化していないか」を
quick.sh の数値で見るのが用途。

### Phase 1 で計測できるもの / できないもの

eval が動かないので named bench は走らない：

| Bench (§9.3 / 1.11) | 動く? | TODO 理由 |
|---|---|---|
| `fib_recursive` | ✗ | 関数呼び出し（Phase 2 TreeWalk） |
| `arith_loop` | ✗ | `loop`/`recur` (Phase 4) |
| `list_build` | ✗ | persistent list (Phase 3) |
| `map_filter_reduce` | ✗ | seq + reduce (Phase 7) |
| `transduce` | ✗ | transducer (Phase 7) |
| `lazy_chain` | ✗ | lazy seq (Phase 7) |

代わりに quick.sh は Phase 1 で計れるものを計る:

```bash
echo "==> 1. Build (ReleaseFast)"; zig build -Doptimize=ReleaseFast
echo "==> 2. Cold start (no-args)";        bench_run cold_start_us "$BIN"
echo "==> 3. -e \"(+ 1 2)\" round-trip";   bench_run e_plus_round_trip_us "$BIN" -e "(+ 1 2)"
echo "==> 4. Read 100-form expression";    bench_run read_100_forms_us "$BIN" -e "$LONG"
```

| 計測項目 | 何を見る? |
|---------|---------|
| `binary_size_bytes` | §10.3 v0.1.0 target「< 3.5 MB」のガード |
| `cold_start_us` | 同上「< 12 ms」（→ 12000 us） |
| `e_plus_round_trip_us` | exit-criterion path のレイテンシ |
| `read_100_forms_us` | reader のスループット |

`bench/quick_baseline.txt` は **追記のみ**。過去の行を編集しない。
これで「いつ regression が入ったか」を git diff で追える。

```bash
# TODO(phase4): once TreeWalk lands, append rows for:
#   fib_recursive_us, arith_loop_us, list_build_us
# TODO(phase7): once transducers land:
#   map_filter_reduce_us, transduce_us, lazy_chain_us
```

`TODO` の各行は将来の commit ごとに 1 行ずつ消えていく。harness 構造が
phase 進行に追従する設計が形として見える。

### Phase 1.12 — x86_64 cross-arch gate

ROADMAP §11.5（Cross-platform gate）:

> 5  x86_64 cross-arch test (OrbStack Ubuntu) — manual `orb run ...
>    zig build test` — Phase 1.12

`scripts/zone_check.sh --gate` がアーキ非依存の gate なら、これは
**実機で違うアーキで test を走らせる gate**。Phase 1 の最終チェック：

```sh
orb run -m my-ubuntu-amd64 bash -c \
    'cd ~/Documents/MyProducts/ClojureWasmFromScratch && bash test/run_all.sh'
```

NaN-boxing の bit shift, alignment, atomic load/store などが ARM64
(M シリーズ Mac) と x86_64 (Linux server) の両方で同じ振る舞いか
**Day 1 から確認**する。

### 演習 8.3: 1 ファイル分の Reader をゼロから (L3)

ファイル名と公開 API のみ。

```zig
// File: src/eval/reader.zig
//
// pub const ReadError = error{ SyntaxError, NumberError, StringError, OutOfMemory };
//
// pub const Reader = struct {
//     tokenizer: Tokenizer, source: []const u8, allocator: std.mem.Allocator,
//     peeked: ?Token = null, depth: u32 = 0, max_depth: u32 = 1024,
//     file_name: []const u8 = "unknown",
//
//     pub fn init(allocator: std.mem.Allocator, source: []const u8) Reader;
//     pub fn read(self: *Reader) ReadError!?Form;
//     pub fn readAll(self: *Reader) ReadError![]Form;
// };
//
// pub fn readOne(allocator: std.mem.Allocator, source: []const u8) ReadError!?Form;
// pub fn readAll(allocator: std.mem.Allocator, source: []const u8) ReadError![]Form;
```

要求:
- `(+ 1 2)`, `[1 :a "b"]`, `{:a 1 :b 2}` が読める
- `'foo` が `(quote foo)` に展開される
- `##NaN` / `##Inf` / `##-Inf` が float Form
- `#_skip 42` が `42` を返す
- 不正な map（奇数長）は `error.SyntaxError`
- ネスト 1024 を超えると `error.SyntaxError`
- 全 Form に `SourceLocation` が貼られる

<details>
<summary>答え骨子</summary>

`init` / `read` / `readAll` の外側はそのまま、内側に `nextToken` /
`locOf` / `readForm` / `readSymbol` / `readInteger` / `readFloat` /
`readString` / `readKeyword` / `readList` / `readVector` / `readMap` /
`readDelimited` / `readQuote` / `readSymbolic` / `readDiscard` /
`unescapeString` を本文どおりに実装する。

```zig
pub fn read(self: *Reader) ReadError!?Form {
    const tok = self.nextToken();
    if (tok.kind == .eof) return null;
    return try self.readForm(tok);
}
```

検証: `bash test/run_all.sh` で 12 個の reader テスト（atoms, escape,
collections, nested, reader macros, readAll, round-trip, syntax errors,
location, comments, bare `/`）が緑。

</details>

---

## 4. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| `read()` の戻り値が `?Form` | ✓ | null = clean EOF と error を型で区別 |
| `read()` が `Form`（EOF も Form） | ✗ | caller が毎回条件分岐を書く |
| 単一 `peeked` で 1-token lookahead | ✓ | LL(1) で十分 |
| 最大ネスト 1024 で固定 | ✓ | 病的入力からの再帰スタック保護 |
| 最大ネスト無制限 | ✗ | `((((((....` で SEGV、攻撃面 |
| map の奇数長を syntax-error | ✓ | analyzer が再チェックなしで反復 |
| Phase 1 CLI が eval まで含む | ✗ | P9 違反。analyzer は Phase 2 別 commit |
| bench/quick.sh を Phase 4 で初導入 | ✗ | binary size / cold start も early baseline 要 |
| bench/quick_baseline.txt を編集可 | ✗ | append-only で git diff から regression |

ROADMAP §A6（≤ 1000 行）：reader 434 行で十分余裕。
ROADMAP §10.2: bench/quick.sh が Phase 4-7 の暫定計測器。
ROADMAP §A7: reader が SourceLocation を全 Form に貼る。

---

## 5. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# Reader 単体（コミット b6efa7f）
git checkout b6efa7f
zig build test 2>&1 | grep -E "(reader|FAIL)"
# → reader.zig 内の 12 個の test が緑

# 最小 CLI（コミット eead562）
git checkout eead562
zig build
./zig-out/bin/cljw                       # → ClojureWasm
./zig-out/bin/cljw -e "(+ 1 2)"          # → (+ 1 2)
./zig-out/bin/cljw -e "[1 :a \"b\"]"     # → [1 :a "b"]
./zig-out/bin/cljw -e "(("               # → Read error: SyntaxError (exit 1)

# bench/quick.sh（コミット 04476ac）
git checkout 04476ac
bash bench/quick.sh
tail -10 bench/quick_baseline.txt

# Phase 1.12 — x86_64 gate（任意）
orb run -m my-ubuntu-amd64 bash -c \
    'cd ~/Documents/MyProducts/ClojureWasmFromScratch && bash test/run_all.sh'

git checkout cw-from-scratch
bash test/run_all.sh
```

---

## 6. 教科書との対比

| 軸 | v1 (`engine/reader/reader.zig`) | v1_ref (`eval/reader.zig`) | Clojure JVM (`LispReader.java`) | 本リポ |
|------|--------|---------|-------------|---------|
| Reader 行数 | 1602 | 607 | 1702 | 434 |
| 戻り値 | `Result(Form, Err)` | `?Form` | `Object` (EOF sentinel) | `!?Form` |
| 1-token lookahead | 専用 buffer | 専用 buffer | `PushbackReader`(1 char) | `peeked: ?Token` |
| 再帰深さ guard | 1024 | 1024 | なし（JVM stack 任せ） | 1024 |
| syntax-quote | reader 内 | reader 内 | `SyntaxQuoteReader` | Phase 2+ で別関数 |
| map 奇数長 | error | error | `IllegalArgumentException` | `error.SyntaxError` |
| location 追跡 | 後付け（Phase 30） | Day 1 | LineNumberingPushbackReader | Day 1 |
| Phase 1 exit | analyzer まで | reader まで | n/a | reader + print のみ |

引っ張られず本リポの理念で整理した点：
- v1 / Clojure JVM は **「reader が 1500+ 行」** の傾向。本リポは
  **434 行**。差は (1) reader macros を Phase 1 で絞った (2)
  syntax-quote 展開を別ファイルに切る (3) 数値の精度保持を Phase 14
  に回した、の 3 点。
- v1 は CLI が **eval まで含めて Phase 1 完了** とした。本リポは
  **Read + Print 往復だけで Phase 1 完了**として、analyzer / VM /
  primitive を Phase 2 commit に分離 (P9 厳守)。Phase boundary review
  chain (continue skill) が動く粒度。
- Clojure JVM は LispReader が AST と eval の両方を見る設計（REPL
  最適化）。本リポは **Form を中間表現に挟み**、TreeWalk と VM の両
  backend で同じ Form を共有 (P12)。

---

## 7. Feynman 課題

6 歳の自分に説明するつもりで答える。

1. なぜ `Reader.read()` の戻り値が **`?Form`** であって `Form` でない
   のか？ 1 行で。
2. Phase 1 の CLI が **`eval` を含まない** のはなぜ？ 1 行で。
3. 何も最適化していない Phase 1 で **bench/quick.sh** を入れる意味は？
   1 行で。

---

## 8. チェックリスト

- [ ] 演習 8.1: 4 つの input に対して `read()` の戻り値を即答できた
- [ ] 演習 8.2: `parseArgs` を `ArgsResult` シグネチャだけから書けた
- [ ] 演習 8.3: Reader 全体を公開 API リストだけから再構成できた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `cljw -e "(+ 1 2)"` の Phase 1 動作を即実演できる
- [ ] `bench/quick.sh` を実行して `quick_baseline.txt` の差分を読める

---

## 次へ

第 0009 章: [Runtime Handle と 3 層分離](./0009-runtime-handle-three-layers.md)

— Phase 2 の入口。`Runtime` ハンドルが `std.Io` を **依存注入** で
受け取る仕組み、`runtime/eval/lang` 3 層が **vtable パターン** で
循環依存を解く方法、そして「なぜ Phase 2 で初めて `Value` と `Form` が
出会うのか」を見ていきます。
