---
chapter: 3
commits:
  - 61ccbf8
related-tasks:
  - §9.3 / 1.2
related-chapters:
  - 0002
  - 0004
date: 2026-04-27
---

# 0003 — エラー基盤 — SourceLocation と threadlocal last_error

> 対応 task: §9.3 / 1.2 / 所要時間: 60〜90 分

ClojureWasm は **原則 P6 (Error quality is non-negotiable)** を Day 1
から有効にします。**エラー位置 (`<file>:<line>:<col>`)** と **構造化
された `Info` ペイロード** を全エラーに付与し、Reader でも Analyzer
でも TreeWalk でも、エラーの読み心地を一貫させるための土台をここで
作ります。

Zig の `error{ ... }!T` には文字列メッセージを乗せられない、という
制約をどう回避するかが設計の主題です。**threadlocal な `last_error`**
を 1 つ持ち、`Error` タグを返すと同時に Info を書き込む方式を
採ります。

---

## この章で学ぶこと

- `SourceLocation` の最小構成（`file` / `line` / `column`）と「未知=0」
  方針
- `Kind` (12 種の意味カテゴリ) と Zig `Error` タグの **1:1 対応**
- Zig の error union は payload を持てない → **threadlocal `last_error`**
  という回避策
- `setErrorFmt` の責務（Info を書く + 対応する Error タグを返す）
- `BuiltinFn` シグネチャ `fn ([]Value, SourceLocation) Error!Value` —
  なぜ Phase-1 から `loc` を渡すのか
- `expect*` / `checkArity*` のヘルパで「型・arity チェック」が **1 行で
  全エラー位置を出せる**こと

---

## 1. なぜエラー基盤を Day 1 に作るのか

### 後付けの惨状（v1 の轍）

`~/Documents/MyProducts/ClojureWasm` は 18 ヶ月かけて作った先代
ランタイム（v1）です。そこでは **error.zig が Phase 後半まで存在
しておらず**、`error.OutOfMemory` のような Zig 標準エラーが裸で
投げられていました。結果として、Phase 30+ で位置情報を後付けしよう
としたとき、**500+ のエラー site すべて** を書き直す羽目になり
ました。

ClojureWasm v2（本リポジトリ）は ROADMAP 原則 **P6** を Day 1 から
据えることで、この罠を踏まないようにしています。

> P6: **Error quality is non-negotiable**. From day 1: file/ns/line/col/
> source-context/colour/stack trace.

§A7 (Concurrency and errors are designed in on day 1) も同じことを
言っています。「あとで足す」は技術的にも認知的にも禁止です。

### 演習 3.1: SourceLocation を読む (L1 — 予測検証)

`src/runtime/error.zig` 23-29 行目:

```zig
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    /// 1-based; 0 = unknown.
    line: u32 = 0,
    /// 0-based.
    column: u16 = 0,
};
```

以下の **`SourceLocation{}`** リテラルから値を予測してください：

```zig
const a = SourceLocation{};
const b = SourceLocation{ .file = "core.clj" };
const c = SourceLocation{ .file = "core.clj", .line = 42, .column = 5 };
```

Q1: `a.file` の値は？
Q2: `a.line` の値は？ なぜそれが「未知」を意味する？
Q3: `b.line` / `b.column` の値は？
Q4: `column` だけ `u16` で他は `u32` の理由を 1 行で。

<details>
<summary>答え</summary>

**Q1**: `"unknown"` (デフォルト)

**Q2**: `0`。「1-based; 0 = unknown」という慣例なので、行番号 0 は
ありえない値 → センチネルとして使えます。`Optional(u32)` を選ばずに
**ゼロ値で sentinel** にしているのは、`SourceLocation{}` という
リテラルを `null` チェックなしで使い回せるようにするためです。

**Q3**: 両方 `0`（つまり「ファイル名だけ判っていて、位置は未知」）。
これは Reader が EOF で出すエラーや、CLI の `-e` 引数で
`file = "<eval>"` だけ判っているケースで自然に使えます。

**Q4**: 1 行: 1 行が 65535 列を超えることは現実上ありえないので
（`u16` で十分、`u32` は無駄）。バイト幅を切り詰めるための最適化
です。

</details>

---

## 2. Zig の error union が payload を運べない問題

Zig の関数は `Error!T` を返せるが、**`Error` は単なるタグ enum** で
あって、メッセージや位置情報を持たせられない:

```zig
const Error = error{ TypeError, ArityError, ... };

fn check(x: Value) Error!Value {
    return error.TypeError;       // ← 「どの値が」「どこで」起きたかは伝わらない
}
```

`Error!T` は **2 word** の表現（タグ + payload）に近い形でコンパイル
されますが、payload は `T` 用に予約されているので、**ユーザ側が
好きな情報を乗せる場所はありません**。

### 解決: threadlocal な「最後のエラー」

C 系言語の `errno` の発想を借ります。エラー時に **構造化 Info を
threadlocal バッファに書き込んでから**、Zig の `Error` タグだけを
返します。`catch |err|` 側は `getLastError()` で詳細を取り出します。

```zig
//! src/runtime/error.zig

threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;

pub const Info = struct {
    kind: Kind,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},
};
```

ポイント:

- `threadlocal var` — Zig の組み込み機能。各スレッドが独立した値を
  持ちます。
- `[512]u8` の固定バッファに `bufPrint` で書き込みます。**動的に
  alloc しない** ので OOM 経路でも動きます。
- `?Info` (optional) — 未取得時の null と区別できます。

### Clojure 動的 var との整合

Clojure では `*out*` / `*err*` / `*ns*` などの **動的 var** は
**スレッドごとにバインディング** を持ちます（per-thread `Var`
rebind）。本リポジトリの threadlocal `last_error` も同じ意味論で
スレッドに閉じます。**Phase 15 の concurrency 拡張で問題にならない**
ことが、この時点で保証されます。

ROADMAP §7.3:
> Dynamic vars stay on threadlocal — per-thread `Var` binding stack
> mirrors `pushThreadBindings` from JVM Clojure.

つまり「`last_error` を threadlocal にする」のは、Clojure の意味論
との **意図的な一致** であって、偶然の最適化ではありません。

### `setErrorFmt` の構造

```zig
pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        @memcpy(msg_buf[509..512], "...");
        break :blk msg_buf[0..512];
    };
    last_error = .{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    };
    return kindToError(kind);
}
```

3 つの仕事をしています：

1. **メッセージを書く**: `bufPrint` で 512 byte の buffer に書き込み
   ます。オーバーフロー時は末尾を `"..."` に潰すフォールバック付き。
2. **Info を保存**: kind / phase / message / location を構造体に
   書き込みます。
3. **Error タグを返す**: `kindToError(kind)` で Zig 側の error タグ
   へ 1:1 で写します。`return setErrorFmt(...)` という 1 行で
   すべて完結します。

### 演習 3.2: setErrorFmt を書き起こす (L2 — 部分再構成)

シグネチャだけ与えるので、本体を実装してください:

```zig
threadlocal var last_error: ?Info = null;
threadlocal var msg_buf: [512]u8 = undefined;

pub const Info = struct { ... };
pub const Error = error{ TypeError, ArityError, ... };
const Kind = enum { type_error, arity_error, ... };

fn kindToError(k: Kind) Error { /* 1:1 mapping */ }

pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    // ここから書く
}
```

要件:

- `bufPrint` のオーバーフロー時は末尾 3 byte を `"..."` に潰す
- 戻り値は `kindToError(kind)`

<details>
<summary>答え</summary>

```zig
pub fn setErrorFmt(
    phase: Phase,
    kind: Kind,
    location: SourceLocation,
    comptime fmt: []const u8,
    args: anytype,
) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch blk: {
        @memcpy(msg_buf[509..512], "...");
        break :blk msg_buf[0..512];
    };
    last_error = .{
        .kind = kind,
        .phase = phase,
        .message = msg,
        .location = location,
    };
    return kindToError(kind);
}
```

ポイント:

- `catch blk: { ... break :blk ... }` は Zig のラベル付きブロック式
  です。エラー時の回復値を式として返せます。
- `@memcpy(msg_buf[509..512], "...")` で末尾 3 byte を上書きし、
  buffer 全長 512 を返しています（truncate を示す表現として）。
- `return` 1 行で副作用と戻り値を兼ねており、呼び出し側は
  `return setErrorFmt(.eval, .type_error, loc, "f: bad arg", .{})`
  のようにすっきり書けます。

</details>

---

## 3. `BuiltinFn` シグネチャ — `loc` を渡すのは Phase 1 から

組み込み関数（Phase 1 の `+` / `-` / `=` 等）の型は:

```zig
pub const BuiltinFn = *const fn (args: []const Value, loc: SourceLocation) Error!Value;
```

`loc` を **第 2 引数** に置く決断が、章末の演習 3.3 まで続く伏線に
なります。

### なぜ `loc` を受け取らせるのか

builtin の中で型エラーを出すとき、**呼び出し側のソース位置**が必要に
なる。例:

```clj
(+ 1 :foo)   ;; ← この位置を `+` 内の TypeError に乗せたい
```

`+` の中で `setErrorFmt(.eval, .type_error, loc, ...)` と書けば、
呼び出し側（`(+ ...)` という Form）の位置がエラーに付与されます。
`loc` を引数にしておかないと、Phase 後半で **全 builtin の
シグネチャを書き直す** 羽目になります（v1 の Phase 30 で実際に
起きました）。

### `expect*` ヘルパ

builtin 1 個 1 個に「型チェック → エラー返却」を手書きさせると
書き方がブレます。`expect*` で集約しておきます:

```zig
pub fn expectNumber(val: Value, name: []const u8, loc: SourceLocation) Error!f64 {
    return switch (val.tag()) {
        .integer => @floatFromInt(val.asInteger()),
        .float => val.asFloat(),
        else => setErrorFmt(.eval, .type_error, loc,
            "{s}: expected number, got {s}", .{ name, tagName(val) }),
    };
}
```

すると `+` の実装は:

```zig
pub fn plus(args: []const Value, loc: SourceLocation) Error!Value {
    var sum: f64 = 0;
    for (args) |arg| sum += try expectNumber(arg, "+", loc);
    return Value.initFloat(sum);
}
```

エラー位置の引き渡しが **`try expectNumber(arg, "+", loc)`** という
1 行に潰れます。

### `checkArity*` ヘルパ

同じく arity エラー:

```zig
pub fn checkArity(name: []const u8, args: []const Value, expected: usize, loc: SourceLocation) Error!void {
    if (args.len != expected) {
        return setErrorFmt(.eval, .arity_error, loc,
            "Wrong number of args ({d}) passed to {s}", .{ args.len, name });
    }
}
```

3 種類: `checkArity` (exact) / `checkArityMin` (≥) / `checkArityRange`
(min..max)。

### Phase 2+ への伏線

`loc` を Phase 1 から渡しているもう 1 つの理由は、Phase 2 で
**`(rt, env, args, loc)`** に signature を拡張するとき、`loc` の枠を
すでに掘ってあるからです。`error.zig` 冒頭のコメント:

```zig
/// Signature of a Phase-1 primitive function. Phase 2+ extends this to
/// `(rt, env, args, loc)`; the typedef will then move to `dispatch.zig`.
pub const BuiltinFn = *const fn (args: []const Value, loc: SourceLocation) Error!Value;
```

**「将来こちらに広げる」という宣言を doc-comment に書いておく** のが
ポイントです。「P6 を Day 1 から」と「P2 (final shape on day 1)」の
合わせ技と言えます。

### 演習 3.3: builtin を 1 つ書き起こす (L3 — 完全再構成)

ファイル名と公開 API のみ与える:

- File: `src/lang/primitive/math.zig` (の一部) — Phase 2 の話だが
  Phase 1 の `BuiltinFn` 規約だけで十分書ける
- 公開 API:
  - `pub fn lessThan(args: []const Value, loc: SourceLocation) Error!Value`
  - 仕様: `(< 1 2 3) → true` / `(< 3 2 1) → false` / `(< 1) → true`
    （単項は常に true）/ `(<)` → `ArityError`
  - 全引数は数値であること。違ったら `TypeError`

ヒント: `expectNumber(val, name, loc)` と `checkArityMin` を使う。

<details>
<summary>答え骨子</summary>

```zig
const error_mod = @import("../../runtime/error.zig");
const SourceLocation = error_mod.SourceLocation;
const Error = error_mod.Error;

pub fn lessThan(args: []const Value, loc: SourceLocation) Error!Value {
    try error_mod.checkArityMin("<", args, 1, loc);
    if (args.len == 1) return .true_val;

    var prev = try error_mod.expectNumber(args[0], "<", loc);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const cur = try error_mod.expectNumber(args[i], "<", loc);
        if (!(prev < cur)) return .false_val;
        prev = cur;
    }
    return .true_val;
}
```

検証ポイント:

- `(< 1 :foo)` → `TypeError`、メッセージは `"<: expected number, got keyword"`、
  位置は呼び出し側の Form の `loc`
- `(<)` → `ArityError`、`"Wrong number of args (0) passed to <, expected at least 1"`
- builtin 内では一切 `setErrorFmt` を直接呼ばない — ヘルパ経由で済む

これが **P6 の「1 site = 1 行」コスト** の正体です。

</details>

---

## 4. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| **threadlocal Info + Zig Error タグ 1:1** | ✓ | error union が payload を運べない制約に対し、最小コストの追加。Clojure の動的 var 意味論とも整合 (§7.3) |
| `Error!*Info` を返す | ✗ | error union の payload は `T` 専有、別 channel が要る |
| `Result(T, Info)` 自前 union | ✗ | Zig の `try`/`catch` syntactic sugar が使えない、書き味が悪い |
| OOM 経路で `Info` を heap alloc | ✗ | `OutOfMemory` 中に alloc は自殺 — 固定 buffer に潰す |
| 各 phase で独自 error 型 | ✗ | `Error.TypeError` を Reader / Analyzer / TreeWalk が共有できないと、ヘルパが書けない |
| Java の `RuntimeException` 風 string only | ✗ | Kind が引けず後段の error formatter が壊れる |

ROADMAP § P6 / §A7 / §7.3 と整合。

---

## 5. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout 61ccbf8
zig build test
# error.zig の test 群が緑（22 ケース、最後の "BuiltinFn signature compiles
# and is invocable" を含む）

# 戻る
git checkout cw-from-scratch
```

エラーが threadlocal で運ばれることを **目で見る** には:

```zig
// scratch.zig
const std = @import("std");
const err = @import("src/runtime/error.zig");

pub fn main() !void {
    err.clearLastError();
    _ = err.setErrorFmt(.eval, .type_error, .{
        .file = "core.clj", .line = 7, .column = 3,
    }, "expected number, got {s}", .{"keyword"}) catch {};

    const info = err.peekLastError().?;
    var buf: [256]u8 = undefined;
    const rendered = err.formatError(info, &buf);
    std.debug.print("{s}\n", .{rendered});
    // → type_error [eval] at core.clj:7:3
    //     expected number, got keyword
}
```

---

## 6. 教科書との対比

| 軸 | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref | Clojure JVM | 本リポ |
|----|------|------|------|------|
| 採用時期 | Phase 30 後付け | Phase 1.2 Day 1 | Day 1 (`Throwable`) | Phase 1.2 Day 1 |
| 位置情報 | 後付け、Reader 由来は欠落 | `SourceLocation` 構造体 | `clojure.lang.Compiler$CompilerException` | `SourceLocation` 構造体 |
| payload 運搬 | 標準 Zig error 裸投げ | threadlocal Info | `getMessage()` / `ex-data` | threadlocal Info |
| Kind 列挙 | 緩い文字列 | 12 種 enum | 多数の `XxxException` | 12 種 enum |
| arity helper | builtin 各々で手書き | 集約済み (`checkArity*`) | `RT.toArray` 群 | 集約済み (`checkArity*`) |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は「位置情報は後段で集めればよい」と判断した結果、Phase 30 で
  500+ 箇所を書き直すことになりました。本リポジトリは
  **`BuiltinFn` の引数に `loc` を Day 1 から組み込んでいます**。
- Clojure JVM の `Throwable` 階層は **Class explosion** の温床です。
  本リポジトリは `Kind` enum 12 種で **フラットに** 管理しています
  （ROADMAP §A6 ≤ 1000 LOC の方針にも適合）。

---

## 7. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. なぜ Zig の `Error!T` だけではエラー詳細を運べないのか。1 行で。
2. なぜ `last_error` を **threadlocal** にするのか。1 行で。
3. `BuiltinFn` の `loc` 引数は何のために存在するのか。1 行で。

---

## 8. チェックリスト

- [ ] 演習 3.1: `SourceLocation` のデフォルト値を即答できる
- [ ] 演習 3.2: `setErrorFmt` をシグネチャだけから書ける
- [ ] 演習 3.3: `<` builtin を `expectNumber` / `checkArityMin` 経由で書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] ROADMAP §P6 / §A7 / §7.3 を即座に指せる

---

## 次へ

第 4 章: [Arena GC — suppress_count と gc-stress](./0004-arena-gc.md)

— Phase 1 の `ArenaGc` は「個別 free を行わず、`deinit` で全部解放
する」という single allocator です。さらに Day 1 から
**`suppress_count`**（マクロ展開中の collection を抑止）と
**`gc_stress`** flag（Phase 5 mark-sweep のテスト用）を仕込んで
おく仕組みを掘り下げます。
