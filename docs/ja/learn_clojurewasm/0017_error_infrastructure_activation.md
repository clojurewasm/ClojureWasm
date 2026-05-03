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
ようになります。

```
<-e>:1:0: type_error [eval]
  (+ 1 :foo)
  ^
+: expected number, got keyword
```

source ファイル名・行・列・kind・phase・該当ソース行・caret・人間
向けメッセージが揃います。**4 commit でここまで来る** — 設計の連続性が
肝なので、各 task を順番に追います。

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

Phase 1.2 (`b6efa7f`) の段階で `error.zig` には全部入っていました。

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
を呼びません。Analyzer も同じ。TreeWalk も同じ。`main.zig` の catch は
`stderr.print("Eval error: {s}\n", .{@errorName(err)})` と書いていた
ので、**`last_error` は populate されないまま、tag 名だけ表示される**
状態でした。

`cljw -e '(+ 1 :foo)'` を打つと

```
Eval error: TypeError
```

これでは **どこで何が起きたか何もわからない**。原則 P6 が空文と化します。

> **核心**: インフラは「乗り物」、call site が「運転手」。乗り物だけ
> あっても誰も乗らなければ何も運ばれない。

3.1–3.4 は乗り物に **段階的に** 運転手を乗せていく作業です。3.1 で
**描画器** (renderer) を完成させ、3.2 で **Reader**、3.3 で
**Analyzer**、3.4 で **TreeWalk + primitives** を順に乗せます。

---

## 2. §9.5/3.1: 描画器と CLI エントリポイント

### `error_print.zig` の役割

`runtime/error.zig::formatError` (Phase 1.2) は header と message
だけ表示します。

```
type_error [eval] at <-e>:1:0
  +: expected number, got keyword
```

これは **source 行 + caret** が無く、ユーザは「どの場所」がわかりません。

3.1 では `runtime/error_print.zig` を新設します。

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

ポイントは **ソーステキストを引数で受ける** ことです。threadlocal
キャッシュ (`error.zig::set_source_text`) という案も検討しましたが、
`main.zig` がすでにソーステキストを持っているのに global state を
新たに作るのは余計（§P3「核は安定」）と判断しました。

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

境界条件は次のようになります。

| 入力              | 戻り値  | 説明                                       |
|-------------------|---------|--------------------------------------------|
| `("abc", 1)`      | `"abc"` | 単一行ソース、line 1 はそのまま返る        |
| `("a\nb\n", 3)`   | `null`  | 末尾 `\n` の後ろの空行を line 3 と数えない |
| `("", 1)`         | `null`  | 空ソースに line 1 は無い                   |
| `("foo\nbar", 2)` | `"bar"` | 末尾に改行がない多行ソースの最終行も拾える |

教科書（Babashka）は「physical line ベース、trailing newline は
terminator として扱う」流儀です。本リポジトリもそれに合わせ、
`line_start == source.len` を null 判定の境界に据えています。

### CLI エントリポイント: `<file>` と `-` (stdin) を昇格

Phase 1〜2 では `cljw -e <expr>` だけが入口でした。が、`-e` は zsh の
history expansion (`!`)、`$` 展開、`` `cmd` ``、glob (`*foo*`) と
衝突しやすい (`.claude/rules/cljw_invocation.md` 参照) ことが
わかっています。

3.1 では `cljw <file.clj>` と `cljw -` (stdin / heredoc) を
**最初から一級** にします。

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

stdin は `readerStreaming` (positional 不可) を使う点に注意します。
`allocRemaining(arena, .unlimited)` は EOF まで読みきって arena に
slice を返す canonical な Zig 0.16 idiom です。

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
するのが鍵です。3.1 単独ではまだ Reader/Analyzer/TreeWalk は
`setErrorFmt` を呼ばないので、フォールバック経路がほぼ毎回使われます。
3.2–3.4 で段階的に活性化していきます。

---

## 3. §9.5/3.2: Reader → setErrorFmt

Reader は `error.SyntaxError` / `NumberError` / `StringError` を直接
返していた 13 箇所を `setErrorFmt(.parse, kind, loc, fmt, args)` に
切替えます。各 token は `tok.line` / `tok.column` を持つので、
`locOf(tok)` ヘルパで `SourceLocation` に変換するだけで済みます。

### ReadError の widening

```zig
// before
pub const ReadError = error{
    SyntaxError, NumberError, StringError, OutOfMemory,
};

// after
pub const ReadError = error_mod.Error;  // 12 タグ全部
```

Zig の error set はサブタイピング可能で、`expectError(error.SyntaxError, ...)`
形式の既存テストは無修正で通ります。広げた set のうち実際に投げるのは
4 タグだけですが、setErrorFmt の return 型が `error_mod.Error` 全部な
ので **型整合のため** に widen する必要があります。

### 不一致パーレンの caret 位置

`cljw -e '(+ 1 2'` を打つと次の出力になります。

```
<-e>:1:0: syntax_error [parse]
  (+ 1 2
  ^
Unmatched delimiter; reached EOF before ')'
```

caret は **opener** (`(`) の位置 (column 0) を指します。理由は
`readDelimited` の EOF パスにあります。

```zig
if (tok.kind == .eof)
    return error_mod.setErrorFmt(.parse, .syntax_error, opener_loc,
        "Unmatched delimiter; reached EOF before '{s}'", .{closingText(closing)});
```

`opener_loc` を渡しているので、**閉じてない `(` がどこか** を即座に
指します。EOF 位置を指すと「行末で何が起きた?」と読み手は遡らざるを
得ない。設計判断として opener を選びました。

---

## 4. §9.5/3.3: Analyzer → setErrorFmt

同じパターンを Analyzer に適用します。違いは次の 2 点です。

1. **Form は既に `location` を持っている** — token から作る必要が
   なく、`form.location` をそのまま渡せます。これは Phase 1 の Reader
   が Form に loc を付けていた成果です。
2. **`Kind.not_implemented` を新設** — Analyzer は
   `AnalyzeError.NotImplemented` を「Phase-3 で実装予定」マーカー
   として持っていましたが、`error_mod.Kind` には対応するタグが無かった。
   ユーザ向け分類 ("phase 限定" vs "値が不正") が異なるので独立タグを
   足しました。

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
switch で結びます。exhaustive check のおかげで 3 箇所のいずれかを忘れる
と compile 失敗するのが安全装置になります。

### name_error の 3 段階メッセージ

未定義シンボル `foo.bar/baz` を解決しようとしたとき、namespace
`foo.bar` 自体が無い場合と、namespace はあるが `baz` が無い場合で
**メッセージを変える** のが本リポジトリの選択です。

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

3 段階のメッセージが出ます。

1. namespace 自体が無い → `"No namespace: 'foo.bar'"`
2. current_ns が無い (起動順異常) → 内部状態異常
3. namespace はあるが symbol が無い → `"Unable to resolve symbol: 'foo.bar/baz'"`

ユーザは `(require 'foo.bar)` を忘れたのか、`baz` を typo したのか
を区別できます。

---

## 5. §9.5/3.4: TreeWalk + primitives → setErrorFmt

最深部です。ここで初めて `(+ 1 :foo)` の eval 時の type 違いを caret
付きで出せるようになります。

### `dispatch.CallFn` シグネチャ拡張

primitive `plus(rt, env, args, loc)` は最初から `loc` を受け取る
シグネチャです。**しかし** TreeWalk の `callBuiltin` は

```zig
return fn_ptr(rt, env, args, .{});  // 空 loc
```

と空 loc を渡していました。理由は `vt.callFn(rt, env, callee, args)`
に loc が無いからです。

3.4 では vtable を一段拡張します。

```zig
pub const CallFn = *const fn (
    rt: *Runtime, env: *Env, fn_val: Value,
    args: []const Value, loc: SourceLocation,  // 追加
) anyerror!Value;
```

`evalCall` から `n.loc` を渡し、`treeWalkCall` → `callBuiltin` →
primitive まで一気通貫で運びます。これで `+` が `expectNumber` 失敗時に
**call-site の location** で `setErrorFmt` を呼べるようになります。

### caret は何を指すか — 残された設計負債

`(+ 1 :foo)` を eval したとき、現状の caret は column 0 (opening
paren) を指します。`:foo` 位置 (column 5) を指すには **per-arg
location** を `expectNumber` まで運ぶ必要があり、これは Phase 9 で
導入予定です。最小の構造変更でいうと：

1. `dispatch.BuiltinFn` に `arg_locs: []const SourceLocation` を追加。
2. `evalCall` で各 arg の `arg_node.loc()` を集めて配列で渡す。
3. `expectNumber` を `expectNumber(val, name, loc, arg_idx, arg_locs)`
   に拡張。

これで `(+ 1 :foo)` → caret は column 5 (`:foo` の `:` 位置) を指せる
ようになります。`SourceLocation` に `length: u16 = 1` を追加すると
caret 幅も `^^^^` (token 幅) にできます。3.1 のサーベイで分離した
設計負債です。

### `error.ArityMismatch` → `error.ArityError`

math primitive が `return error.ArityMismatch;` を返していたところ
を `setErrorFmt(.eval, .arity_error, loc, ...)` に置換します。**戻り値の
tag 名が変わる** ので、`expectError(error.ArityMismatch, ...)` のテスト
は `error.ArityError` に書き換える必要があります。

これを忘れると false negative — テストはパスするのに実際は別 tag
で投げるという不一致が発生します。Zig は anyerror 経由で任意の名前を
許すので **名前の typo に気付きづらい** という落とし穴に該当します。

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
§A2「新機能は新ファイル」を `error_print.zig` 新設で守りました。

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
  ようにしています。Babashka は ex-info メタの中に持ちますが、本リポ
  ジトリでは caller がソーステキストを持っているため、わざわざ
  グローバル状態を増やす理由がないからです。
- `Kind.not_implemented` を独立タグにしています。JVM の
  `UnsupportedOperationException` に近い位置付けですが、本リポジトリ
  の Phase 番号入りメッセージ（"Phase 3.5+" など）をユーザに見せる
  前提でラベリングしています。

---

## この章で学んだこと

- 結局のところこの章は **「乗り物（インフラ）に運転手（call site）
  を 4 段階で乗せた」** 章です。Reader → Analyzer → TreeWalk →
  primitive の各層が `setErrorFmt` を呼ぶようになって初めて
  threadlocal `last_error` が populate され、P6 が空文でなくなります。
- `SourceContext` を引数で渡したのは、`main.zig` がすでにソース
  テキストを持っているのに新しい threadlocal を増やさないためです。
- `dispatch.CallFn` に `loc` を加えなければ、primitive まで call-site
  の位置情報が運べないという構造的制約が、vtable シグネチャに刻まれて
  います。

---

## 次へ

第 18 章: Phase 3 / §9.5 タスク 3.5–3.7（heap collections と macro
経路）。エラー基盤が動き始めた今、いよいよ string / list / vector を
**Value として** 扱う heap 表現に入っていきます。
