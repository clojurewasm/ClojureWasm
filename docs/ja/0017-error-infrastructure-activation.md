---
chapter: 17
commits:
  - 37f0c8f
  - 8c750b5
  - 5eb3fc7
  - 6777c42
related-tasks:
  - §9.5 / 3.1
  - §9.5 / 3.2
  - §9.5 / 3.3
  - §9.5 / 3.4
related-chapters:
  - 0016
  - "—"
date: 2026-04-27
---

# 0017 — エラー基盤の活性化（Reader → Analyzer → TreeWalk → primitives）

> 対応 task: §9.5 / 3.1–3.4 / 所要時間: 60〜90 分

Phase 1.2 で `runtime/error.zig` に **`SourceLocation` / `Kind` /
`Phase` / threadlocal `last_error` / `setErrorFmt`** を作って以来、
インフラはずっと **そこにあった** のに、Reader / Analyzer / TreeWalk
/ primitive のどこも使っていませんでした。`cljw -e '(+ 1 :foo)'` を
打つと `Eval error: TypeError` という、**位置情報も理由も持たない**
痩せた文字列だけが返ってきていたわけです。

この章では Phase 3 の最初の 4 タスク（§9.5 / 3.1–3.4）を通して、
**ROADMAP §2 原則 P6「Error quality is non-negotiable」を end-to-
end で活性化** させます。完了後は同じ式で次のような出力が得られる
ようになります：

```
<-e>:1:0: type_error [eval]
  (+ 1 :foo)
  ^
+: expected number, got keyword
```

source ファイル名・行・列・kind・phase・該当ソース行・caret・人間
向けメッセージが揃う。**4 commit でここまで来る** — 設計の連続性が
肝なので、各 task を順番に追う。

---

## この章で学ぶこと

- 既存インフラ (`SourceLocation` / `setErrorFmt` / threadlocal
  `last_error`) を「**使う側**」がどう接続するか
- `error_print.formatErrorWithContext(info, ctx, w, opts)` の設計：
  なぜ `SourceContext` を引数で受けるか / threadlocal にしないか
- `cljw <file.clj>` / `cljw -` (stdin) を一級エントリポイントに
  昇格させる実装と、なぜ `-e` だけだと脆いか (zsh history expansion)
- Reader/Analyzer/TreeWalk が **同じパターン** で `setErrorFmt` 経由に
  切替わる過程 — その 4 段階の意義
- `dispatch.CallFn` シグネチャに `loc: SourceLocation` を追加した
  理由 — primitive まで call-site 位置を運ぶ唯一の方法
- error set の widening (`pub const ReadError = error_mod.Error`)
  という Zig 固有のテクニック

---

## 1. なぜ「インフラは在ったが使われていなかった」のか

Phase 1.2 (`b6efa7f`) の段階で `error.zig` には全部入っていた：

```zig
// src/runtime/error.zig (snapshot)
pub const SourceLocation = struct {
    file: []const u8 = "unknown",
    line: u32 = 0,        // 1-based; 0 = unknown
    column: u16 = 0,      // 0-based
};

pub const Kind = enum { syntax_error, type_error, name_error, ... };
pub const Phase = enum { parse, analysis, macroexpand, eval };

pub const Info = struct {
    kind: Kind,
    phase: Phase,
    message: []const u8,
    location: SourceLocation = .{},
};

threadlocal var last_error: ?Info = null;

pub fn setErrorFmt(
    phase: Phase, kind: Kind, location: SourceLocation,
    comptime fmt: []const u8, args: anytype,
) Error {
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch ...;
    last_error = .{ .kind = kind, .phase = phase, .message = msg, .location = location };
    return kindToError(kind);
}
```

しかし Reader は `return error.SyntaxError;` と返すだけで `setErrorFmt`
を呼ばない。Analyzer も同じ。TreeWalk も同じ。`main.zig` の catch は
`stderr.print("Eval error: {s}\n", .{@errorName(err)})` と書いていた
ので、**`last_error` は populate されないまま、tag 名だけ表示される**
状態。

`cljw -e '(+ 1 :foo)'` を打つと

```
Eval error: TypeError
```

これでは **どこで何が起きたか何もわからない**。原則 P6 が空文と化す。

> **核心**: インフラは「乗り物」、call site が「運転手」。乗り物だけ
> あっても誰も乗らなければ何も運ばれない。

3.1–3.4 は乗り物に **段階的に** 運転手を乗せていく作業：3.1 で
**描画器** (renderer) を完成させ、3.2 で **Reader**、3.3 で
**Analyzer**、3.4 で **TreeWalk + primitives** を順に乗せる。

---

## 2. §9.5/3.1: 描画器と CLI エントリポイント

### `error_print.zig` の役割

`runtime/error.zig::formatError` (Phase 1.2) は header と message
だけ表示する：

```
type_error [eval] at <-e>:1:0
  +: expected number, got keyword
```

これは **source 行 + caret** が無く、ユーザは「どの場所」がわからない。

3.1 では `runtime/error_print.zig` を新設：

```zig
pub const SourceContext = struct {
    file: []const u8,    // 表示ラベル: "<-e>" / "<stdin>" / "script.clj"
    text: []const u8,    // 全ソーステキスト — 該当行の抽出に使う
};

pub fn formatErrorWithContext(
    info: error_mod.Info,
    ctx: SourceContext,
    w: *Writer,
    opts: Options,
) Writer.Error!void { ... }
```

ポイントは **ソーステキストを引数で受ける** こと。threadlocal キャッシュ
(`error.zig::set_source_text`) という案も検討したが、`main.zig` がすでに
ソーステキストを持っているのに global state を新たに作るのは余計
(§P3「核は安定」)。

### `extractLine`: 該当行を抽出

```zig
pub fn extractLine(source: []const u8, line_num: u32) ?[]const u8 {
    if (line_num == 0) return null;
    var current_line: u32 = 1;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (current_line == line_num) return source[line_start..i];
            current_line += 1;
            line_start = i + 1;
        }
    }
    if (current_line == line_num and line_start < source.len)
        return source[line_start..];
    return null;
}
```

### 演習 17.1: `extractLine` の境界条件 (L1 — predict)

以下の入力で何が返るか答えよ。

```zig
extractLine("abc", 1)         // (a)
extractLine("a\nb\n", 3)      // (b)
extractLine("", 1)            // (c)
extractLine("foo\nbar", 2)    // (d)
```

<details>
<summary>答え</summary>

- **(a)** `"abc"` — 単一行ソース、line 1 はそのまま返る。
- **(b)** `null` — 末尾に `\n` があっても、その後ろの空行を line 3
  と数えない (`line_start < source.len` でガード)。
- **(c)** `null` — 空ソースに line 1 は無い。
- **(d)** `"bar"` — 末尾に改行がない多行ソースの最終行も拾える。

理由: 教科書 (Babashka) は「physical line ベース、trailing newline は
terminator として扱う」流儀。CW v2 もそれに合わせ、`line_start ==
source.len` を null 判定の境界に据えた。

</details>

### CLI エントリポイント: `<file>` と `-` (stdin) を昇格

Phase 1〜2 では `cljw -e <expr>` だけが入口だった。が、`-e` は zsh の
history expansion (`!`)、`$` 展開、`` `cmd` ``、glob (`*foo*`) と
衝突しやすい (`.claude/rules/cljw-invocation.md` 参照)。

3.1 では `cljw <file.clj>` と `cljw -` (stdin / heredoc) を
**最初から一級** にする：

```zig
} else if (std.mem.eql(u8, arg, "-")) {
    const stdin_file = std.Io.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.readerStreaming(io, &stdin_buf);
    source_text = try stdin_reader.interface.allocRemaining(arena, .unlimited);
    source_label = "<stdin>";
} else {
    const file = try std.Io.Dir.cwd().openFile(io, arg, .{});
    defer file.close(io);
    var file_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &file_buf);
    source_text = try file_reader.interface.allocRemaining(arena, .unlimited);
    source_label = arg;
}
```

stdin は `readerStreaming` (positional 不可) を使う点に注意。
`allocRemaining(arena, .unlimited)` は EOF まで読みきって arena に
slice を返す canonical な Zig 0.16 idiom。

### catch サイトの切替

```zig
const result = tree_walk.eval(...) catch |err| {
    try renderError(stderr, ctx, err);
    std.process.exit(1);
};

fn renderError(stderr: *Writer, ctx: error_print.SourceContext, err: anyerror) Writer.Error!void {
    if (error_mod.getLastError()) |info| {
        try error_print.formatErrorWithContext(info, ctx, stderr, .{});
    } else {
        try stderr.print("{s}: error: {s}\n", .{ ctx.file, @errorName(err) });
    }
    try stderr.flush();
}
```

`getLastError()` が `null` のときに `@errorName(err)` にフォールバック
するのが鍵。3.1 単独ではまだ Reader/Analyzer/TreeWalk は `setErrorFmt`
を呼ばないので、フォールバック経路がほぼ毎回使われる。3.2–3.4 で
段階的に活性化していく。

---

## 3. §9.5/3.2: Reader → setErrorFmt

Reader は `error.SyntaxError` / `NumberError` / `StringError` を直接
返していた 13 箇所を `setErrorFmt(.parse, kind, loc, fmt, args)` に
切替える。各 token は `tok.line` / `tok.column` を持つので、`locOf(tok)`
ヘルパで `SourceLocation` に変換するだけで済む。

### ReadError の widening

```zig
// before
pub const ReadError = error{
    SyntaxError, NumberError, StringError, OutOfMemory,
};

// after
pub const ReadError = error_mod.Error;  // 12 タグ全部
```

Zig の error set はサブタイピング可能 — `expectError(error.SyntaxError, ...)`
形式の既存テストは無修正で通る。広げた set のうち実際に投げるのは
4 タグだけだが、setErrorFmt の return 型が `error_mod.Error` 全部な
ので **型整合のため** に widen する必要がある。

### 演習 17.2: 不一致パーレンの caret 位置 (L2 — predict & verify)

`cljw -e '(+ 1 2'` を打つと何が出るか予想せよ。caret はどの位置を
指すか / 指す理由は？

<details>
<summary>答え</summary>

```
<-e>:1:0: syntax_error [parse]
  (+ 1 2
  ^
Unmatched delimiter; reached EOF before ')'
```

caret は **opener** (`(`) の位置 (column 0)。理由は `readDelimited`
の EOF パス：

```zig
if (tok.kind == .eof)
    return error_mod.setErrorFmt(.parse, .syntax_error, opener_loc,
        "Unmatched delimiter; reached EOF before '{s}'", .{closingText(closing)});
```

`opener_loc` を渡しているので、**閉じてない `(` がどこか** を即座に
指す。EOF 位置を指すと「行末で何が起きた?」と読み手は遡らざるを
得ない。設計判断として opener を選んだ。

</details>

---

## 4. §9.5/3.3: Analyzer → setErrorFmt

同じパターンを Analyzer に適用する。違いは：

1. **Form は既に `location` を持っている** — token から作る必要が
   なく、`form.location` をそのまま渡せる。これは Phase 1 の Reader
   が Form に loc を付けていた成果。
2. **`Kind.not_implemented` を新設** — Analyzer は
   `AnalyzeError.NotImplemented` を「Phase-3 で実装予定」マーカー
   として持っていたが、`error_mod.Kind` には対応するタグが無かった。
   ユーザ向け分類 ("phase 限定" vs "値が不正") が異なるので独立タグを
   足した。

```zig
// src/runtime/error.zig
pub const Kind = enum {
    syntax_error, number_error, string_error,
    name_error, arity_error, value_error, not_implemented,
    type_error, arithmetic_error, index_error,
    io_error, internal_error, out_of_memory,
};

pub const Error = error{
    SyntaxError, NumberError, StringError,
    NameError, ArityError, ValueError, NotImplemented,
    TypeError, ArithmeticError, IndexError,
    IoError, InternalError, OutOfMemory,
};
```

`Kind.not_implemented` ⇄ `Error.NotImplemented` は `kindToError` の
switch で結ぶ — exhaustive check のおかげで 3 箇所のいずれかを忘れる
と compile 失敗するのが安全装置になる。

### 演習 17.3: name_error メッセージ (L2 — design)

未定義シンボル `foo.bar/baz` を解決しようとしたとき、最も親切な
エラーメッセージはどう書くか。namespace `foo.bar` 自体が無い場合と、
namespace はあるが `baz` が無い場合で **メッセージを変えるべきか**。

<details>
<summary>答え</summary>

CW v2 の選択：**メッセージを変える**。

```zig
const ns = if (sym.ns) |ns_name|
    env.findNs(ns_name) orelse return error_mod.setErrorFmt(.analysis, .name_error,
        form.location, "No namespace: '{s}'", .{ns_name})
else
    env.current_ns orelse return error_mod.setErrorFmt(.analysis, .name_error,
        form.location, "No current namespace; cannot resolve '{s}'", .{sym.name});
const v_ptr = ns.resolve(sym.name) orelse return error_mod.setErrorFmt(
    .analysis, .name_error, form.location,
    "Unable to resolve symbol: '{s}'", .{symFullName(sym)});
```

3 段階のメッセージ：

1. namespace 自体が無い → `"No namespace: 'foo.bar'"`
2. current_ns が無い (起動順異常) → 内部状態異常
3. namespace はあるが symbol が無い → `"Unable to resolve symbol: 'foo.bar/baz'"`

ユーザは `(require 'foo.bar)` を忘れたのか、`baz` を typo したのか
を区別できる。

</details>

---

## 5. §9.5/3.4: TreeWalk + primitives → setErrorFmt

最深部。ここで初めて `(+ 1 :foo)` の eval 時の type 違いを caret 付き
で出せる。

### `dispatch.CallFn` シグネチャ拡張

primitive `plus(rt, env, args, loc)` は最初から `loc` を受け取る
シグネチャ。**しかし** TreeWalk の `callBuiltin` は

```zig
return fn_ptr(rt, env, args, .{});  // 空 loc
```

と空 loc を渡していた。理由は `vt.callFn(rt, env, callee, args)` に
loc が無いから。

3.4 では vtable を一段拡張：

```zig
pub const CallFn = *const fn (
    rt: *Runtime, env: *Env, fn_val: Value,
    args: []const Value, loc: SourceLocation,  // 追加
) anyerror!Value;
```

`evalCall` から `n.loc` を渡し、`treeWalkCall` → `callBuiltin` →
primitive まで一気通貫で運ぶ。これで `+` が `expectNumber` 失敗時に
**call-site の location** で `setErrorFmt` を呼べるようになる。

### 演習 17.4: caret は何を指すか (L3 — full reconstruction)

`(+ 1 :foo)` を eval したとき、現状の caret は column 0 (opening
paren) を指す。実装変更なしで `:foo` 位置 (column 5) を指すには
**何が必要か**。最小の変更で最大の効果はどう設計するか、提案せよ。

<details>
<summary>答え骨子</summary>

**現状不可。** `loc` は call_node 全体の位置 (= `(`)。`:foo` 位置を
指すには **per-arg location** を `expectNumber` まで運ぶ必要がある。

**提案** (Phase 9 で導入予定):

1. `dispatch.BuiltinFn` に `arg_locs: []const SourceLocation` を追加。
2. `evalCall` で各 arg の `arg_node.loc()` を集めて配列で渡す。
3. `expectNumber` を `expectNumber(val, name, loc, arg_idx, arg_locs)`
   に拡張。

これで `(+ 1 :foo)` → caret は column 5 (`:foo` の `:` 位置)。

別途、`SourceLocation` に `length: u16 = 1` を追加すると caret 幅も
`^^^^` (token 幅) にできる。3.1 のサーベイで分離した設計負債。

</details>

### `error.ArityMismatch` → `error.ArityError`

math primitive が `return error.ArityMismatch;` を返していたところ
を `setErrorFmt(.eval, .arity_error, loc, ...)` に置換。**戻り値の
tag 名が変わる** ので、`expectError(error.ArityMismatch, ...)` のテスト
は `error.ArityError` に書き換える必要がある。

これを忘れると false negative — テストはパスするのに実際は別 tag
で投げるという不一致が発生する。Zig は anyerror 経由で任意の名前を
許すので **名前の typo に気付きづらい** という落とし穴に該当。

---

## 6. 設計判断と却下した代替

| 案                                                   | 採否 | 理由                                                                      |
|------------------------------------------------------|------|---------------------------------------------------------------------------|
| `SourceContext` を引数渡し                           | ✓   | threadlocal を増やさない (§P3)                                           |
| ソーステキストを threadlocal cache                   | ✗   | `main.zig` が既に持っている、global state 増やす意味なし                  |
| `Kind.not_implemented` を別タグ                      | ✓   | "phase 限定" vs "値が不正" を区別したい                                   |
| `internal_error` で代用                              | ✗   | "ランタイムバグ" と混同される                                             |
| `EvalError` を絞ったまま `@errorCast` で narrow      | ✗   | runtime panic 危険、type 拡張のほうが対称性良い                           |
| token 幅 caret を 3.4 に含める                       | ✗   | `SourceLocation.length` 後付け改造大、Phase 9 へ分離                      |
| エイリアス `pub const NotCallable = error.TypeError` | ✗   | error set のドットアクセスは tag 引きなので構文的に成立せず compile error |
| catch サイトで loc を後付けで付ける                  | ✗   | 既に正しい loc を持つエラーを上書きする危険                               |

ROADMAP §2 / 原則 P6 への対応：原則 P6「Error quality is non-negotiable」
を Reader → Analyzer → TreeWalk → primitive の 4 階層全部で活性化。
§A2「新機能は新ファイル」を `error_print.zig` 新設で守った。

---

## 7. 確認 (Try it)

```sh
git checkout 6777c42

zig build && zig-out/bin/cljw -e '(+ 1 :foo)' 2>&1
# 期待:
# <-e>:1:0: type_error [eval]
#   (+ 1 :foo)
#   ^
# +: expected number, got keyword

zig-out/bin/cljw -e '(+ 1 2'  2>&1
# 期待:
# <-e>:1:0: syntax_error [parse]
#   (+ 1 2
#   ^
# Unmatched delimiter; reached EOF before ')'

zig-out/bin/cljw -e 'undefined-symbol'  2>&1
# 期待:
# <-e>:1:0: name_error [analysis]
#   undefined-symbol
#   ^
# Unable to resolve symbol: 'undefined-symbol'

# stdin (heredoc) も同じ catch サイトを通る
zig-out/bin/cljw - <<'EOF'
(+ 1 :foo)
EOF
# 期待: source ラベルが <stdin> になる以外は同じ

bash test/run_all.sh    # 全 suite green
```

---

## 8. 教科書との対比

| 軸                      | v1          | v1_ref      | Clojure JVM            | Babashka                | 本リポジトリ                            |
|-------------------------|-------------|-------------|------------------------|-------------------------|-----------------------------------------|
| エラー位置の保持        | threadlocal | threadlocal | exception attribute    | ex-info の data map     | threadlocal `last_error` (v1 と同じ)    |
| ソース行の表示          | header のみ | header のみ | REPL が別途取得        | ±4/±6 行 + 単一 caret | 該当行 + 単一 caret (Babashka に近い)   |
| caret 幅                | 無し        | 無し        | 無し                   | 単一 column             | 単一 column (token 幅は Phase 9)        |
| primitive への loc 伝搬 | 後付け      | 後付け      | exception trace で代用 | ex-info                 | dispatch.CallFn に loc を最初から含める |
| not_implemented 扱い    | internal    | internal    | UnsupportedOpEx        | ex-info                 | 専用 Kind タグ                          |

引っ張られずに本リポジトリの理念で整理した点：

- ソーステキストを threadlocal にせず、引数 `SourceContext` で渡す
  ようにしています。Babashka は ex-info メタの中に持ちますが、CW v2
  では caller がソーステキストを持っているため、わざわざグローバル
  状態を増やす理由がないからです。
- `Kind.not_implemented` を独立タグにしています。JVM の
  `UnsupportedOperationException` に近い位置付けですが、CW v2 の
  Phase 番号入りメッセージ（"Phase 3.5+" など）をユーザに見せる
  前提でラベリングしています。

---

## 9. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. `error.zig` のインフラが Phase 1.2 で完成していたのに、Phase 3
   でやっと使われ始めたのはなぜか。1 行で。
2. `cljw -e "(+ 1 :foo)"` の caret が column 0（`(`）を指して、
   column 5（`:foo`）を指さないのはなぜか。1 行で。
3. `pub const ReadError = error_mod.Error` と「広げて」いるのに、
   外側の `expectError(error.SyntaxError, ...)` テストが壊れない
   のはなぜか。1 行で。

---

## 10. チェックリスト

- [ ] 演習 17.1 の (a)-(d) 全部正解できる
- [ ] 演習 17.2 で caret 位置と理由を 1 文で言える
- [ ] 演習 17.3 で 3 段階のメッセージ設計を再現できる
- [ ] 演習 17.4 の Phase 9 提案を白紙から書ける
- [ ] Feynman 3 問を 1 行ずつで答えられる
- [ ] ROADMAP §9.5 の 3.1–3.4 と原則 P6 を即座に指せる

---

## 次へ

第 18 章: Phase 3 / §9.5 タスク 3.5–3.7（heap collections と macro
経路）。エラー基盤が動き始めた今、いよいよ string / list / vector を
**Value として** 扱う heap 表現に入っていきます。
