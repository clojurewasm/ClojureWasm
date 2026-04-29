<!-- Per-concept chapter. docs/ja/learn_clojurewasm/0020_phase3_completion.md -->

---
chapter: 20
commits:
  - 772ebcf
  - 28c2bc3
  - c16380f
  - 99efd07
  - a1a70aa
  - f725f58
  - 22881a1
  - 8e63134
  - 399cb31
  - 4ad8270
related-tasks:
  - §9.5 / 3.8
  - §9.5 / 3.9
  - §9.5 / 3.10
  - §9.5 / 3.11
  - §9.5 / 3.12
  - §9.5 / 3.13
  - §9.5 / 3.14
related-chapters:
  - 0019
  - "—"
date: 2026-04-27
---

# 0020 — Phase 3 の閉幕：例外と反復、ブートストラップ、修正方針

> 対応 task: §9.5 / 3.8〜3.14 / 所要時間: 120〜180 分

Phase 3 の後半は性格の異なる三つの仕事が一気に折り重なる章です。
ひとつ目は `try` / `catch` / `throw` / `loop*` / `recur` を AST から
評価器まで通す **例外と反復** の仕事、ふたつ目は `cljw` 起動時に
`core.clj` を読み込む **Stage-1 ブートストラップ** の仕事、みっつ目は
ROADMAP §17 の **修正方針** に従って ADR 0002 を発行し、Phase-3 の
出口判定を整える仕事です。本章はこの三つを別々に並べるのではなく、
「Phase 3 が閉じるまでに何が必要だったのか」という一本の物語として
読めるように構成します。最後の `phase3_exit.sh` が green になった瞬間
までを追いかけます。

---

## この章で学ぶこと

- `printValue` を Layer 0 の専用ファイルに切り出すことで、印字の
  責務がどの層から見ても呼べる形になる理由
- `try` / `catch` / `throw` / `loop*` / `recur` を **AST だけ先行で**
  入れてから評価器を後回しにする二段階実装の意味
- `error.RecurSignaled` / `error.ThrownValue` を制御フローに使う Zig
  慣用句と、threadlocal な payload 受け渡しの組み合わせ
- closure の slot snapshot 方式と、`fn_node.slot_base` がなぜ必要に
  なるのか
- `@embedFile` でブートストラップ用の Clojure ソースをバイナリに
  焼き込む設計と、`defn` を Zig マクロとして実装した理由
- ROADMAP §17 の四ステップ修正手順と、その初回適用例である ADR 0002
  が果たす役割

---

## 1. `print.zig` を切り出す（task 3.8）

### 1.1 なぜ Layer 0 に分離するのか

Phase 2 までの `printValue` / `printList` / `printString` は
`main.zig` に同居していました。`renderError` がまだ `main.zig` に
あった頃の名残ですが、Phase 3 で **印字** を要求する呼び出し元が
増えるため、これを一箇所に集めておく必要があります。具体的には次の
場面が該当します。

- REPL のプロンプトと結果表示（Layer 3）
- エラー文中で Value を埋め込む `error_print` 経由の呼び出し（Layer 0）
- 将来の `pr-str` primitive（Layer 2）

これらが `main.zig`（Layer 3）の関数に依存すると、`runtime/` から
上向きの import が必要になり zone 違反になります。`runtime/print.zig`
へ移して Layer 0 に閉じ込めれば、どの層からでも素直に呼べます。

```zig
// src/runtime/print.zig（snapshot）
pub fn printValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag()) {
        .nil_val => try w.writeAll("nil"),
        .bool_val => try w.writeAll(if (v.asBool()) "true" else "false"),
        .int_val => try w.print("{d}", .{v.asInt()}),
        .keyword_val => try printKeyword(w, v),
        .string_val => try printString(w, v),
        .list_val => try printList(w, v),
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}
```

`else` arm は **未対応の HeapTag を `#<tag-name>` として落とす** 既定
動作を持ちます。Phase 3 段階の `transient_vector` や `fn_val` のように
専用分岐がまだない型もここで安全に処理されます。新しい heap kind を
足したとき（3.10 で `ex_info` を入れたとき）には、`else` arm の前に
分岐を 1 つ書き足すだけで済む形になっています。

### 1.2 移動の最小性を守る

3.8 は機械的なリファクタリングです。「移動ついでに書き直したい」誘惑
は強いものの、ここで shape を変えるとレビューが破綻します。本リポ
ジトリでは関数名と引数名を変えず、`pub` する位置だけ動かす最小手術に
留めました。代わりに 5 種類の単体テスト（atom / keyword / 文字列の
エスケープ / 入れ子 list / 未対応タグの fallback）を回帰用ガードと
して同コミットに含めています。

### 演習 1.1: print 切り出し (L1 — 穴埋め)

```zig
// printValue は switch を使って tag ごとに分岐する。
// 未対応のタグに当たったとき、印字結果はどの形になるか。
else => |t| try w.print("____", .{@tagName(t)});
```

Q1: 上のフォーマット文字列に入る正しい値は何か。
Q2: なぜ `else` arm が exhaustive のために必須なのか。

<details>
<summary>答え</summary>

**Q1**: `"#<{s}>"`。

**Q2**: Zig 0.16 の `switch` は tagged union に対して exhaustive を
要求します。ここでは `Value.tag()` が `HeapTag` enum を返し、
`transient_vector` などの未対応タグも enum メンバーとして既に存在する
ため、`else` を欠くと compile error になります。`else` arm が安全な
fallback として存在するおかげで、新しい HeapTag を増設しても
`print.zig` 側の追従は段階的に済みます。

</details>

---

## 2. 例外と反復の AST 先行（task 3.9）

### 2.1 二段階で攻める理由

`try` / `catch` / `throw` / `loop*` / `recur` は意味論が複雑です。
`recur` は tail-position チェックを必要としますし、`try` の `finally`
は成功・捕捉・未捕捉の三状態それぞれで挙動が異なります。これを評価器
まで一気に通すと変更面積が大きくなり、テストが何を保証しているのか
読み解けなくなります。

そこで 3.9 は **AST を整える仕事だけ** に絞りました。`Node` に
`loop_node` / `recur_node` / `try_node` / `throw_node` の 4 バリアント
を追加し、Analyzer が Form を Node に落とすロジックを書きます。
`tree_walk.eval` 側は switch arm を 4 つ足して `not_implemented` を
返すだけにとどめます。実評価は 3.11 へ持ち越します。

```zig
// src/eval/node.zig（抜粋・snapshot）
pub const Node = union(NodeTag) {
    // ... 既存のバリアント ...
    loop_node: LoopNode,
    recur_node: RecurNode,
    try_node: TryNode,
    throw_node: ThrowNode,
};

pub const TryNode = struct {
    body: *const Node,
    catch_clauses: []const CatchClause,
    finally: ?*const Node,
};

pub const CatchClause = struct {
    class_name: []const u8,
    binding_slot: u32,
    body: *const Node,
};
```

### 2.2 flat な catch_clauses にする

v1 は `try` を **catch ごとに入れ子の TryNode** で表現していました。
最初の catch 節を内側 TryNode に押し込み、外側 TryNode が次の catch を
受け持つ作りです。これは JVM bytecode の例外テーブルに近い構造ですが、
AST としては読みづらく、multi-class catch を増やすたびに backend の
ロジックも入れ子に追従する必要があります。

引っ張られずに本リポジトリの理念で整理した点：

- 本リポジトリは Clojure JVM の `TryExpr.catchExprs: PersistentVector`
  に寄せて **flat な配列** で持ちます。Phase 3 では `class_name` が
  `"ExceptionInfo"` 1 種類だけですが、Phase 5+ で multi-catch / Class
  解決が来たときに線形 walk のロジックをそのまま拡張できます。
- ROADMAP §13 が「marker dict / class hierarchy を避ける」と書いて
  いる方針とも整合します。

### 2.3 `recur_target_depth` を u32 で持つ

`Scope` には新たに `recur_target` と `recur_target_depth: u32` を
持たせます。3.9 で実利用するのは「target が存在するか」と「arity が
合うか」の判定だけなので、boolean でも十分に見えます。それでも u32 に
した理由は、将来 named loop や labelled break を導入したときに Scope
契約を再エンジニアリングせずに済ませるためです（ROADMAP A2）。

`Scope.child` は深さを +1 し、`Scope.childWithRecur` は target を
再設定して 0 にリセットする関数として分けます。`let*` は前者を、
`fn*` / `loop*` は後者を呼びます。**`let*` が target を持たない** のは
Clojure 仕様であり、`(let [x 1] (recur ...))` は `let` を貫通せず
外側の `fn*` / `loop*` の target を見にいきます。

### 2.4 tail-position チェックは 3.11 に持ち越す

3.9 では `recur` の **target 不在** と **arity 不一致** の 2 種類だけ
エラー化します。tail-position チェック（`recur` が末尾位置にあるかの
判定）は `is_tail` フラグを `analyze` 全体に thread する大きな変更に
なるため、評価器の形が見えてから 3.11 で codegen 寄りに入れることに
しました。

### 演習 2.1: TryNode の形 (L2 — 部分再構成)

`(try 1 2 (catch ExceptionInfo e 3))` を Analyzer に通したとき、
`TryNode.body` はどんな形になるか。次のシグネチャを満たすように
`buildTryBody` を書いてください。

```zig
fn buildTryBody(arena: std.mem.Allocator, body_forms: []const Form) !*Node {
    // body_forms.len == 0 のとき nil constant
    // body_forms.len == 1 のとき その 1 form を analyze した結果
    // body_forms.len >= 2 のとき (do body...) として束ねる
}
```

ヒント:
- `if` / `let*` / `fn*` の既存ヘルパと一致させる
- 単一 form を強制的に `do_node` でラップしない

<details>
<summary>答え</summary>

```zig
fn buildTryBody(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: *Scope,
    body_forms: []const Form,
    macro_table: *const MacroTable,
) !*Node {
    if (body_forms.len == 0) {
        return makeConstantNode(arena, .nil_val);
    }
    if (body_forms.len == 1) {
        return analyze(arena, rt, env, scope, body_forms[0], macro_table);
    }
    return analyzeDo(arena, rt, env, scope, body_forms, macro_table);
}
```

ポイント:
- `(try 1 ...)` の body は constant `1` であって `(do 1)` ではありません
- multi-form のときだけ `do_node` でくるむのは `if` / `let*` / `fn*`
  の helper と同じ慣用です

</details>

### 演習 2.2: arity 不一致エラー (L1 — 穴埋め)

```clojure
(loop* [x 0] (recur 1 2))
```

このプログラムを Analyzer が拒否する理由を 1 行で答えてください。

<details>
<summary>答え</summary>

`loop*` の binding が `[x 0]` で arity 1 を宣言しているのに、`recur`
が 2 引数を渡しているため、Analyzer が `expected 1 arg, got 2` の
syntax_error を返します。tail-position は 3.9 では問いませんが、
arity だけは AST 構築時に検証します。

</details>

---

## 3. `ex-info` を heap struct として導入する（task 3.10）

### 3.1 marker key map ではなく専用タグへ

v1 は `(ex-info ...)` を **`PersistentArrayMap` に
`:__ex_info → true` のマーカーキー** を仕込んだ Value として表現して
いました。一方 ClojureWasm v2 は `HeapTag.ex_info` を専用に取り、
`runtime/collection/ex_info.zig` で 3 フィールドの struct を用意します。

引っ張られずに本リポジトリの理念で整理した点：

- 専用タグにすると `Value.tag() == .ex_info` の **1 cmp** で識別でき
  ます。marker key map は dispatch のたびに map lookup が走るので、
  ROADMAP §13 の「marker dict / class hierarchy を避ける」方針に
  沿わせるだけで自然と高速化されます。

```zig
// src/runtime/collection/ex_info.zig（snapshot）
pub const ExInfo = struct {
    message: []const u8,
    data: Value,
    cause: Value,

    pub fn alloc(
        rt: *Runtime,
        msg_bytes: []const u8,
        data_v: Value,
        cause_v: Value,
    ) !Value {
        const ptr = try rt.gpa.create(ExInfo);
        ptr.* = .{ .message = msg_bytes, .data = data_v, .cause = cause_v };
        return Value.encodeHeapPtr(.ex_info, ptr);
    }

    pub fn message(val: Value) []const u8 { ... }
    pub fn data(val: Value) Value { ... }
    pub fn cause(val: Value) Value { ... }
};
```

### 3.2 `cause` をいま入れる判断

3.10 のサーベイは「ROADMAP A6（≤1000 行）に沿って `cause` を後回し
にする」ことを推奨していました。実際に書いてみると `ex_info.zig` は
~150 行で A6 のリスクは小さく、struct への `Value` 1 個追加は些細な
作業でした。Clojure JVM の 3-arg 形（`ExceptionInfo(msg, data, cause)`）
と整合させた方が、後から field を増設する churn より安く付くと
判断しました。**サーベイ推奨を本ノート（task note）の判断で上書き**
した最初の例であり、決定権限が小規模変更については task 側にある
実例です。

### 3.3 `ex-message` は **新規 String を確保して返す**

```zig
pub fn exMessage(rt: *Runtime, _: *Env, args: []const Value, _: SourceLocation) !Value {
    const v = args[0];
    if (v.tag() != .ex_info) return .nil_val;
    const ex = v.asHeapPtr(ExInfo);
    return string_collection.alloc(rt, ex.message);
}
```

`ExInfo` 内部の `message: []const u8` は ExInfo struct と運命を共に
します。`ex-message` がその slice を **そのまま返す** と、Phase 5+ の
GC 後に `ExInfo` が回収された瞬間に dangling slice になります。
代わりに `string_collection.alloc` で **新しい String Value** を確保
して返せば、Value の lifetime が ExInfo から独立します。1 行のコスト
で、回収順序のバグを永久に潰せる安全な作りになります。

### 3.4 print 形式

`runtime/print.zig` には `.ex_info` 用の arm を 1 行足します。
描画形式は Clojure JVM の pr-str に倣い `#error{:message "..." :data ...}`
です。`cause` が `nil` のときは省略します。

```zig
.ex_info => {
    const ex = v.asHeapPtr(ExInfo);
    try w.print("#error{{:message \"{s}\" :data ", .{ex.message});
    try printValue(w, ex.data);
    if (ex.cause.tag() != .nil_val) {
        try w.writeAll(" :cause ");
        try printValue(w, ex.cause);
    }
    try w.writeAll("}");
},
```

### 演習 3.1: ex-message の安全性 (L2 — 概念)

`ex-message` が ExInfo 内部の slice をそのまま返してはいけない理由
を、Phase 5+ の GC を念頭に置いて説明してください。

<details>
<summary>答え</summary>

`ExInfo` が GC で回収されると、`message: []const u8` が指していた
バイト列の所有権が消えます。slice をそのまま返したと仮定すると、その
後に caller がその Value を保持しているにもかかわらず、ポインタの先は
すでに解放済みになってしまいます。`string_collection.alloc` で別の
heap 領域に新しい String を確保しておけば、Value はそれ自身の
lifetime を持ち、ExInfo の回収とは無関係になります。GC trace の観点
でも独立した root を持つので安全です。

</details>

---

## 4. tree_walk が例外と反復を実行する（task 3.11）

### 4.1 `error.RecurSignaled` + threadlocal の組み合わせ

Zig には例外がないので、`recur` の制御フローは **payload のない error
タグ** で表現します。`evalRecur` は recur 引数を全て評価したあと、
`pending_recur_buf` という threadlocal slice にコピーし、
`error.RecurSignaled` を raise します。`evalLoop` は body を `catch` で
くるみ、このタグを受けたら slice を locals に書き戻して loop の先頭
からやり直します。

```zig
// src/eval/backend/tree_walk.zig（要旨）
threadlocal var pending_recur_buf: [MAX_LOCALS]Value = undefined;
threadlocal var pending_recur_len: usize = 0;

fn evalRecur(rt: *Runtime, env: *Env, locals: *[MAX_LOCALS]Value, n: *const Node) !Value {
    const args = n.recur_node.args;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        pending_recur_buf[i] = try eval(rt, env, locals, args[i]);
    }
    pending_recur_len = args.len;
    return error.RecurSignaled;
}

fn evalLoop(rt: *Runtime, env: *Env, locals: *[MAX_LOCALS]Value, n: *const Node) !Value {
    // 初期束縛を locals に書く
    for (n.loop_node.bindings, 0..) |b, i| {
        locals[n.loop_node.slot_base + i] = try eval(rt, env, locals, b.init);
    }
    while (true) {
        if (eval(rt, env, locals, n.loop_node.body)) |v| {
            return v;
        } else |err| switch (err) {
            error.RecurSignaled => {
                @memcpy(
                    locals[n.loop_node.slot_base..][0..pending_recur_len],
                    pending_recur_buf[0..pending_recur_len],
                );
            },
            else => |e| return e,
        }
    }
}
```

引数は **raise の前に** 評価し終えるので、引数自体が失敗した場合
（例えば未定義変数を参照）はそのまま伝播します。これは Zig idiom の
正しい例であり、ROADMAP P10 の「制御フローに error を使ってよい」
方針に合致します。

### 4.2 `error.ThrownValue` + `last_thrown_exception`

`throw` も同じ形ですが、payload に **生の Value 1 個** を載せます。

```zig
// src/runtime/dispatch.zig（要旨）
pub threadlocal var last_thrown_exception: Value = .nil_val;

// src/eval/backend/tree_walk.zig（要旨）
fn evalThrow(rt: *Runtime, env: *Env, locals: *[MAX_LOCALS]Value, n: *const Node) !Value {
    const v = try eval(rt, env, locals, n.throw_node.expr);
    dispatch.last_thrown_exception = v;
    return error.ThrownValue;
}
```

`evalTry` は body を `catch` でくるみ、`error.ThrownValue` を受け取った
場合のみ `dispatch.last_thrown_exception` から Value を取り出して
catch 節と照合します。Phase 3 では catch クラス名は **`"ExceptionInfo"`
ひと種類** だけが `Value.tag() == .ex_info` と一致するルールであり、
将来 multi-class catch が来てもこの string 比較を Class / Var ベースの
解決に置き換えるだけで拡張できます。

### 4.3 finally の三状態

`(try body (catch ... ...) (finally ...))` の意味論は、JVM Clojure と
同じく次の三通りに分かれます。

| 状態                           | finally の挙動         | 最終戻り値       |
|--------------------------------|------------------------|------------------|
| body 成功                      | 実行する               | body の結果      |
| body throw、catch でマッチ     | catch 評価後に実行する | catch の結果     |
| body throw、catch にマッチなし | 実行する               | re-raise（伝播） |

Zig レベルで言うと「(c) 未捕捉ケース」は `error.ThrownValue` を
finally の評価が終わったあとに **再度 raise する** 形になります。
`finally` 自身が throw した場合は元の例外を上書きする、という仕様も
JVM Clojure と一致させてあります。

### 4.4 closure は slot snapshot で実装する

`fn*` を評価したとき、`Function` 構造体は **lexical scope** を保存
する必要があります。v1 は **全 locals** を snapshot していました。

引っ張られずに本リポジトリの理念で整理した点：

- 本リポジトリは Analyzer が決めた `slot_base` までのスロットだけを
  snapshot します。具体的には次の形です。

```zig
fn allocFunction(rt: *Runtime, fn_node: *const FnNode, parent_locals: *const [MAX_LOCALS]Value) !Value {
    const ptr = try rt.gpa.create(Function);
    errdefer rt.gpa.destroy(ptr);

    const slice = try rt.gpa.alloc(Value, fn_node.slot_base);
    @memcpy(slice, parent_locals[0..fn_node.slot_base]);

    ptr.* = .{ .fn_node = fn_node, .closure_bindings = slice };
    return Value.encodeHeapPtr(.fn_val, ptr);
}
```

`callFunction` 側は呼び出しごとに新しい `[MAX_LOCALS]Value` を確保
し、まず `closure_bindings` を `[0, slot_base)` に書き戻し、その上に
今回の引数を `[slot_base, slot_base + arity)` に積みます。LocalRef が
Analyzer の決めた slot index でそのまま参照できるのは、この
`slot_base` のオフセットが call 時に毎回再現されるからです。

実装中に Phase 2 から潜伏していたバグが露呈しました。Phase 2 の
`callFunction` は params を `locals[0..arity]` に書いていたのですが、
nested fn では Analyzer が params を `[slot_base, slot_base + arity)`
に解決しているのに、callFunction が `[0, arity)` に書いているために
LocalRef が拾えません。`slot_base + i` で書き直すと closure と
nested fn が同時に動くようになります。**closure 機能を実装するまで
顕在化しなかった** バグであり、サーベイ段階では気づけませんでした。

### 演習 4.1: closure の所有権 (L2 — 概念)

`closure_bindings` は `rt.gpa` に乗せて allocate し、`freeFunction` で
解放するつくりにしています。なぜ Analyzer の arena に乗せないのか、
理由を 1 行で答えてください。

<details>
<summary>答え</summary>

Analyzer の arena は input loop が一巡したら deinit されるのに対し、
`Function` Value は env / heap の側で生きつづけ、後の呼び出しで
closure を参照するからです。lifetime が異なるので別の allocator に
乗せる必要があります。

</details>

### 演習 4.2: try/finally の流れ (L2 — トレース)

次のプログラムを評価したとき、stdout の順序と最終戻り値を予測して
ください。

```clojure
(try
  (do (prn :body) (throw (ex-info "x" 0)))
  (catch ExceptionInfo e (prn :caught) :handled)
  (finally (prn :finally)))
```

<details>
<summary>答え</summary>

`:body` → `:caught` → `:finally` の順で印字され、最終戻り値は
`:handled` になります。catch がマッチした場合でも finally は走り、
戻り値は catch の結果になります。

</details>

### 演習 4.3: tree_walk の eval 入り口 (L3 — 完全再構成)

ファイル名と公開 API のリストだけから書いてみてください。

要求:
- File: `src/eval/backend/tree_walk.zig`
- Public:
  - `pub const MAX_LOCALS: usize = 256;`
  - `pub fn eval(rt: *Runtime, env: *Env, locals: *[MAX_LOCALS]Value, n: *const Node) anyerror!Value`
  - `pub fn callFn(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value) anyerror!Value`

<details>
<summary>答え骨子</summary>

```zig
//! Tree-walking evaluator for the analyzed Node tree.

const std = @import("std");
const Runtime = @import("../../runtime/runtime.zig").Runtime;
const Env = @import("../../runtime/env.zig").Env;
const Value = @import("../../runtime/value.zig").Value;
const Node = @import("../node.zig").Node;
const dispatch = @import("../../runtime/dispatch.zig");

pub const MAX_LOCALS: usize = 256;

pub fn eval(rt: *Runtime, env: *Env, locals: *[MAX_LOCALS]Value, n: *const Node) anyerror!Value {
    return switch (n.*) {
        .constant => |c| c.value,
        .local_ref => |l| locals[l.slot],
        .if_node => |x| try evalIf(rt, env, locals, &x),
        .let_node => |x| try evalLet(rt, env, locals, &x),
        .do_node => |x| try evalDo(rt, env, locals, &x),
        .fn_node => |x| try allocFunction(rt, &x, locals),
        .call_node => |x| try evalCall(rt, env, locals, &x),
        .loop_node => |x| try evalLoop(rt, env, locals, &x),
        .recur_node => |x| try evalRecur(rt, env, locals, &x),
        .try_node => |x| try evalTry(rt, env, locals, &x),
        .throw_node => |x| try evalThrow(rt, env, locals, &x),
        // ... 残りのバリアント ...
    };
}

pub fn callFn(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value) anyerror!Value {
    // closure を locals に書き戻し、引数を slot_base から積む
    ...
}
```

検証: `bash test/run_all.sh` が green になり、`(loop* [x 0] (if (< x 3)
(recur (+ x 1)) x))` が `3` を返すことを確認します。

</details>

---

## 5. Stage-1 ブートストラップを切り出す（task 3.12）

### 5.1 ニワトリ卵問題の所在

Phase 2 まで `cljw` は起動時に Clojure コードを **何も評価していません
でした**。`+` などの primitive を `primitive.registerAll` で登録し、
9 種類のマクロ（`let` / `when` / `cond` など）を
`macro_transforms.registerInto` で登録するだけで、ユーザ入力を待つ
構造でした。Phase 3 に入って `defn` や `not` を提供したくなったとき、
初めて **起動時に評価される Clojure ソース** が必要になります。

しかしここに非自明な依存があります。`defmacro` をユーザが書けるよう
にするには、user-fn macro 経路（Analyzer が `expandIfMacro` で
user-defined macro を呼ぶ仕組み）が必要です。これは Phase 3 では
未実装であり、3.13 / 3.14 の defn macro 化と並行して整備されます。
そのため 3.12 は **ブートストラップ機構そのもの** に絞り、`defn` /
`defmacro` の Clojure 側定義は後続タスクへ持ち越します。

### 5.2 `lang/bootstrap.zig` の責務

```zig
// src/lang/bootstrap.zig（snapshot）
pub const CORE_SOURCE: []const u8 = @embedFile("clj/clojure/core.clj");
pub const SOURCE_LABEL: []const u8 = "<bootstrap>";

pub fn loadCore(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    macro_table: *const macro_dispatch.Table,
) !void {
    var reader = Reader.init(arena, CORE_SOURCE);
    while (true) {
        const form_opt = try reader.read();
        const form = form_opt orelse break;
        const node = try analyzeForm(arena, rt, env, null, form, macro_table);
        var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
        _ = try tree_walk.eval(rt, env, &locals, node);
    }
}
```

`@embedFile` は **コンパイル時にバイナリへ埋め込む** 命令です。これに
より `cljw` 単体配布で source tree が無くても起動できます。v1 が
`embedded_sources.zig` で multiline string literal にしていたのと
等価ですが、v2 は別ファイル（`src/lang/clj/clojure/core.clj`）に
切り出すことで、シンタックスハイライトと将来の `clj-kondo` リント
対象にできるようにしてあります。

### 5.3 `core.clj` には何を書くか

Phase 3 段階の `core.clj` は最小です。

```clojure
;; ClojureWasm Stage-1 prologue.

(def not (fn* [x] (if x false true)))
```

たった 1 行ですが、これを置く意義は二つあります。一つ目は **regression
の早期検知** で、毎起動でパイプライン全体（reader → analyzer → tree_walk）
が動き続けるため、後の Phase で reader / analyzer に変更を入れたとき、
`core.clj` を読み込めなくなった時点で起動が落ちて気づけます。二つ目は
**今後の拡張点** で、`defmacro` 経路が立った時点で `core.clj` を
「ただの import 経路」から「Clojure-level 定義の住処」に育てていく
ための地ならしになります。

### 5.4 v1 / Upstream / SCI と本リポジトリの差

ブートストラップ戦略は実装ごとに個性が出ます。

| 軸                       | v1                          | Upstream Clojure JVM                   | Babashka / SCI                       | 本リポジトリ                              |
|--------------------------|-----------------------------|----------------------------------------|--------------------------------------|-------------------------------------------|
| `core.clj` の存在        | 廃止し全 44 マクロを Zig 化 | 完全な `core.clj` を runtime ロード    | 親 JVM Clojure から `copy-ns` で取得 | 最小の `core.clj` を残し Zig マクロと併存 |
| compile / runtime の段差 | なし（tree-walk のみ）      | あり（special form は compile 時解決） | なし（SCI は interpreter）           | なし（tree-walk のみ）                    |
| 自己充足性               | binary 単体で起動           | `clojure.jar` に core.clj 同梱         | 親 Clojure 必須                      | binary 単体で起動                         |
| 拡張点                   | Zig 側へ追加                | `core.clj` へ追加                      | 親 Clojure 経由                      | hybrid（Zig 優先 / `core.clj` fallback）  |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は `core.clj` を完全廃止していましたが、本リポジトリは P3
  「core stays stable」を保ちつつ拡張点として `core.clj` を残して
  います
- Upstream は compile / runtime の段差を持っていますが、本リポジトリは
  tree-walk のみで段差をもたず、その違いに合わせて Stage-1 の入り口を
  単純化しています

### 5.5 macro 優先順位

Analyzer のマクロ解決順は次の通りです。

1. lexical local 束縛（最強）
2. Zig fast-path（`macro_transforms.registerInto` で登録された 9 種）
3. user-defined macro（user `defmacro` で作られた Var、3.13+ で実装）

たとえば `core.clj` 側で `(defmacro when [c b] ...)` を書いて Zig の
`when` を上書きしようとしても、Zig table が先勝するため上書きでき
ません。これは「Zig fast-path が常に勝つ」設計の表れで、`core.clj`
を fallback / ドキュメントの層として運用するための前提になっています。

### 演習 5.1: 起動順序の予測 (L1 — 穴埋め)

`main.zig` の startup chain は次の順序で構成されています。

1. `Runtime.init`
2. `Env.init`
3. `installVTable`
4. `____`           ← Q
5. `____`           ← Q
6. `bootstrap.loadCore`
7. user input loop

<details>
<summary>答え</summary>

4 が `primitive.registerAll`、5 が `macro_transforms.registerInto`
です。`loadCore` を `registerAll` の前に置くと、`+` などが未登録の
状態で `core.clj` を評価することになり、もし `core.clj` 内で primitive
を呼ぶ式が増えた瞬間に未定義参照で落ちます。

</details>

---

## 6. `defn` を Zig マクロにして起動チェーンへ繋ぐ（task 3.13）

### 6.1 二つに分けたコミット

3.13 は内容が二つあるので、コミットを 2 本に分けています。

- `f725f58` — `bootstrap.loadCore` を `main.zig` の startup chain に
  挿入する配線
- `22881a1` — `(defn name [params] body...)` を `(def name (fn*
  [params] (do body...)))` に展開する Zig マクロを `macro_transforms.zig`
  に追加

これで `(defn f [x] (+ x 1)) (f 2)` がエンドツーエンドで通るように
なり、Phase-3 の出口の片方が成立します。

### 6.2 `defn` の lowering

```zig
// (defn name [params...] body...) → (def name (fn* [params...] (do body...)))
fn expandDefn(
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) macro_dispatch.ExpandError!Form {
    _ = rt;
    if (args.len < 3) return setErrorFmt(.macroexpand, .syntax_error, loc, "defn requires ...", .{});
    // ... name / params の検証 ...

    const body_form = if (body.len == 1) body[0] else blk: {
        var do_items = try arena.alloc(Form, body.len + 1);
        do_items[0] = sym("do", loc);
        @memcpy(do_items[1..], body);
        break :blk try list(arena, do_items, loc);
    };

    const fn_items = try arena.alloc(Form, 3);
    fn_items[0] = sym("fn*", loc);
    fn_items[1] = params_form;
    fn_items[2] = body_form;
    const fn_form = try list(arena, fn_items, loc);

    const def_items = try arena.alloc(Form, 3);
    def_items[0] = sym("def", loc);
    def_items[1] = name_form;
    def_items[2] = fn_form;
    return list(arena, def_items, loc);
}
```

Stage-1 では surface を意図的に narrow に保ちます。docstring も
metadata map も multi-arity も持たせません。Phase 4+ で user-defined
macro が `core.clj` から `defn` を上書き可能になった時点で、その
責務を Clojure 側へ移していく予定です。

### 6.3 multi-body は `do` で束ねる

`(defn g [x] a b c)` のように body が複数あるとき、`(fn* [x] (do a b
c))` に展開します。`(fn* [x] a b c)` のままだと analyzer は body 部に
複数の form を直接並べる形を想定していないので、`c` が黙って捨てられる
バグになります。Clojure 慣用の暗黙 `do` をマクロ展開時点で開いて
おくのが筋の通った設計です。

### 6.4 `(def ...)` の戻り値は `#<var_ref>`

JVM Clojure の `(def x 1)` は `#'user/x`（Var 参照）を返します。本リポ
ジトリも `var_ref` Value を返しており、printer がそれを `#<var_ref>`
で表示します。Phase-3 exit smoke のテスト期待値としては、このまま
観察できます。

### 演習 6.1: 起動順を入れ替える (L1 — 概念)

`bootstrap.loadCore` が `primitive.registerAll` よりも **前** に走る
ように main.zig を書き換えたとして、`(def not (fn* [x] (if x false
true)))` だけが入った `core.clj` のロードは成功するでしょうか。

<details>
<summary>答え</summary>

成功します。`core.clj` の本文が `def` / `fn*` / `if` という special
form だけで構成されていて primitive を呼んでいないからです。ただし
将来 `core.clj` に `(def inc (fn* [x] (+ x 1)))` のような primitive
依存の式を追加した瞬間に「`+` が見つからない」という未定義参照で
落ちます。Phase 3 段階では事故が表面化していないだけで、起動順は
「primitive → macro → bootstrap」の順序を守るべきものです。

</details>

---

## 7. ROADMAP §17 修正方針と ADR 0002（meta コミット + task 3.14）

### 7.1 何を直したのか

Phase-3 の exit form は ROADMAP §9.5 / 3.14 に書かれています。当初の
文面はこうでした。

```
(try (throw (ex-info "boom" {})) (catch ExceptionInfo e (ex-message e))) → "boom"
```

ところが実装してみると **`{}`（空マップリテラル）が現状の Reader /
Analyzer で通らない** ことが判明しました。`src/eval/analyzer.zig:212`
が `not_implemented` を返し、メッセージは "Map literal as expression
value not yet supported (Phase 3+)" になります。一方 ROADMAP §9 phase
table の上位行は `(defn f [x] (+ x 1)) (f 2) → 3; try/catch works`
という高レベル文面で、map リテラルを要求していません。**§9 phase
table の高レベル行と Phase 5 の collection scope は内部整合していて、
§9.5 / 3.14 の詳細行だけが両方と矛盾していた** という drafting
overreach のケースです。

### 7.2 §17 — Amendment policy の存在意義

ROADMAP §17 はこの種の不整合を **アドホックパッチではなく整備作業
として** 扱うために置かれています。要点は「ROADMAP は now snapshot
であり、後の Phase で見えた依存は遡って修正してよい。ただし手順を
守れ」です。手順は四ステップ。

1. **ROADMAP を直接編集する**（最初からその文面だった体で書き直す）
2. **ADR を起票する**（旧文面・新文面・なぜ食い違っていたかを記録）
3. **handover を同期する**（Active task / Current state を直す）
4. **コミットメッセージから ADR を参照する**（`git log -- .dev/ROADMAP.md`
   で原因が辿れる状態にする）

inline change-bar / dated comment / `~~strikethrough~~` は禁止です。
変更履歴は ROADMAP の中ではなく、**git log + ADR + `docs/ja/`** の
三層に書く方針になっています。

### 7.3 ADR 0002 が下した決定

ADR 0002 は二つの load-bearing decision を記録します。

- **D-A**: Phase 3 の exit smoke は `(ex-info "boom" 0)` を使います
  （`{}` ではなく整数の placeholder）。`ex-info` の `data` slot は
  polymorphic で nil 以外なら何でも通るため、try / throw / catch +
  ex-info の round-trip 意味論を検証する目的は不変です。
- **D-B**: map リテラル対応は Phase 5（HAMT / persistent map と
  まとめて）に置きます。Phase 3 で空マップだけのスタブを置くのは P4
  「no ad-hoc patches」違反になります。printValue arm / equality arm /
  hash 分岐 / deinit 経路を、Phase 5 で本実装する HAMT が継承する形で
  足してしまうため、Phase 5 が clean greenfield ではなく brittle stub
  を引き継ぐリスクが大きいからです。

却下案として「smoke を緩めて任意の data 値を許す」案や「ex-info
smoke 全体を Phase 5 に延期する」案も検討しています。どちらも ADR
0002 本文で明確に拒絶しています — 前者は §17.4 の「ROADMAP は SoT」
原則に反し、後者は Phase 3 で動いている behavior の verify を二相
失うためです。

### 7.4 § 17 の初回適用例として

ADR 0002 は **§17.2 の四ステップを実地で踏んだ最初の例** です。
インフラとしての §17 が「絵に描いた餅」ではなく実際に運用できる手順
であることを、この一件で確認しました。今後 Phase 5 で map リテラルが
ship したとき、§9.5 / 3.14 を canonical な `{}` 形に戻すかどうかの
判断と、`(ex-info "..." {:k v})` を使う Phase 5 exit case の追加が
follow-up として残ります。これも ADR 0002 の "Consequences" 節に
明記してあります。

### 7.5 `phase3_exit.sh` という形（task 3.14）

`phase2_exit.sh` の骨格をそのまま借りて、Phase-3 の exit gate を独立
スクリプトに切り出します。assertion は二つだけです。

```bash
# (defn f [x] (+ x 1)) (f 2) → 3
got=$("$BIN" - <<'EOF' 2>&1
(defn f [x] (+ x 1))
(f 2)
EOF
)
[[ "$got" == $'#<var_ref>\n3' ]] || fail

# (try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e))) → "boom"
run_case "try/throw/catch ex-info round-trip" \
    '(try (throw (ex-info "boom" 0)) (catch ExceptionInfo e (ex-message e)))' \
    '"boom"'
```

`phase3_cli.sh`（plumbing 用の case 群）と分離するのは、Phase-boundary
review で「どこまでが exit 約束か」を曖昧にしないためです。前者は
Phase-3 で組み上げた機能の網羅テスト、後者は exit gate そのもの、と
責務を分けています。`{}` は一切引かず、ADR 0002 へのパスだけを
コメントの根拠として残します。

### 演習 7.1: 修正方針の四ステップ (L2 — 列挙)

ROADMAP §17.2 の四ステップを順に挙げてください。

<details>
<summary>答え</summary>

1. ROADMAP を最初からその文面だった体で直接編集する（change-bar 禁止）
2. ADR を `.dev/decisions/NNNN_<slug>.md` に起票（旧文面・新文面・
   ずれていた理由）
3. `handover.md` の Active task / Current state を同期する
4. ROADMAP 編集を含むコミットメッセージから ADR を参照する

</details>

---

## 8. 設計判断と却下した代替

| 案                                                       | 採否 | 理由                                                                |
|----------------------------------------------------------|------|---------------------------------------------------------------------|
| `printValue` を `value.zig` 内に置く                     | ✗   | `value.zig` の責務肥大化を避けるため Layer 0 内の別ファイルに分離   |
| `printValue` を `lang/primitive/io.zig` (Layer 2) に置く | ✗   | Layer 0/1 から呼べず upward import 違反になる                       |
| `try` を catch ごとに nested TryNode で表現              | ✗   | AST 読解性と multi-catch 拡張性で flat array 方式に劣る             |
| `recur_target` を `bool` で持つ                          | ✗   | arity 検証ができず、named loop に拡張不能                           |
| tail-position チェックを 3.9 で実装                      | ✗   | `is_tail` を analyze 全体に thread する大規模変更を 3.11 へ持ち越す |
| `ex-info` を marker key map で実装（v1 方式）            | ✗   | 専用 HeapTag dispatch のほうが 1 cmp で識別でき高速                 |
| `ex-info` の `cause` を 3.11 へ後回し                    | ✗   | 1 field 追加なら今のほうが安価、JVM の 3-arg 形と整合               |
| `ex-message` が ExInfo の slice をそのまま返す           | ✗   | GC 後に dangle するリスク、新 String の確保 1 行で安全              |
| closure を `[256]Value` 全コピー                         | ✗   | `slot_base` までで意味は十分、GC trace コストを下げる               |
| `recur` を non-error な threadlocal flag で表現          | ✗   | unwind が手間、Zig idiom の error-as-control に揃える               |
| `EvalError` enum に `RecurSignaled` を足す               | ✗   | `kindToError` の Kind 1:1 mapping を壊す                            |
| `bootstrap.loadCore` を `Env.init` 内で呼ぶ              | ✗   | runtime → lang は upward import で zone 違反                       |
| `defn` を `(def name (fn* params body))` だけに展開      | ✗   | 複数 body の暗黙 `do` が壊れて `c` が黙って捨てられる               |
| 空 map リテラル stub を Phase 3 で実装                   | ✗   | P4「no ad-hoc patches」違反、Phase 5 が brittle stub を継承する     |
| smoke の data を「任意の値」と緩める                     | ✗   | ROADMAP は SoT、後で deliberate か bug か判別不能になる             |
| ex-info smoke 全体を Phase 5 へ延期                      | ✗   | Phase-3 で動いている挙動の end-to-end verify が二相失われる         |

ROADMAP の対応箇所：

- §2 P3「core stays stable」— `core.clj` を残す決定の根拠
- §2 P4「no ad-hoc patches」— map literal stub 拒絶の根拠
- §2 P6「Error quality is non-negotiable」— `try` / `catch` まで
  `setErrorFmt` 経由を貫徹
- §2 A2「new feature in new file」— `bootstrap.zig` を独立モジュール化
- §2 A6「≤1000 行」— `ex_info.zig` ~150 行で `cause` 同梱の判断
- §13 — marker dict / class hierarchy 不採用、`pub var` 不採用
- §17 — Amendment policy の四ステップ（ADR 0002 が初回適用）

---

## 9. 確認 (Try it)

```sh
git checkout 399cb31     # Phase-3 exit gate 配線後の HEAD
zig build
bash test/run_all.sh     # 全 suite green
bash test/e2e/phase3_exit.sh
# → ✓ (defn f [x] (+ x 1)) (f 2) → 3
# → ✓ try/throw/catch ex-info round-trip
# → Phase-3 exit-criterion e2e: all green.
```

`./zig-out/bin/cljw -e '(loop* [x 0] (if (< x 3) (recur (+ x 1)) x))'`
で `3` が返り、`./zig-out/bin/cljw -e '(try (throw (ex-info "boom" 0))
(catch ExceptionInfo e (ex-message e)))'` で `"boom"` が返ることを
個別にも確認できます。

---

## 10. 教科書との対比

| 軸                    | v1                            | v1_ref                              | Clojure JVM                              | 本リポジトリ                                         |
|-----------------------|-------------------------------|-------------------------------------|------------------------------------------|------------------------------------------------------|
| `try` の AST 形       | nested TryNode で multi-catch | scaffolding のみ                    | flat `catchExprs: PersistentVector`      | flat `catch_clauses: []const CatchClause`            |
| `recur` 信号          | 専用 frame                    | `error.RecurSignaled` + threadlocal | bytecode `goto loopLabel`                | `error.RecurSignaled` + threadlocal（v1_ref と同形） |
| closure snapshot 範囲 | 全 locals                     | （Phase 2 まで未対応）              | closes map（compile 時）                 | `[0, slot_base)` のみ                                |
| `ex-info` の表現      | marker key 付き map           | tag 確保のみ                        | `ExceptionInfo extends RuntimeException` | 専用 `HeapTag.ex_info` + 3 field struct              |
| `core.clj` の有無     | 廃止（全 Zig 化）             | scaffolding                         | 完全な `core.clj` を runtime ロード      | 最小 `core.clj` を `@embedFile` で同梱               |
| `defn` の住処         | Zig マクロ（44 種の一部）     | 未定義                              | `core.clj` の macro                      | Zig マクロ（Stage-1 narrow surface）                 |
| ROADMAP 修正手順      | （v1 は ADR 文化なし）        | 同上                                | （該当なし）                             | §17 四ステップ（ADR 0002 が初回）                   |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は closure を全 locals snapshot していましたが、本リポジトリは
  Analyzer の決めた `slot_base` までだけを snapshot して GC trace
  コストを抑えています
- v1 は `core.clj` を完全廃止していましたが、本リポジトリは P3
  「core stays stable」を保ちつつ拡張点として `core.clj` を残し、
  Zig マクロが優先されることで P3 と P4 を両立させています
- Clojure JVM は compile 時に special form / catch / recur を解決
  しますが、本リポジトリは tree-walk のみで段差を持たず、その分
  recur / throw を Zig の error-as-control-flow で素直に表現します

---

## 11. Feynman 課題

6 歳の自分に説明するつもりで答えてください。書けなければ理解が
不完全です。

1. なぜ `recur` を Zig の `error` として表現するのか。1 行で。
2. なぜ `try` の `catch_clauses` を入れ子ではなく flat な配列で持つ
   のか。1 行で。
3. なぜ `ex-message` は内部 slice をそのまま返さず新しい String を
   確保するのか。1 行で。
4. なぜ `core.clj` を最小 1 行（`(def not ...)`）でも残しておくのか。
   1 行で。
5. なぜ Phase 3 の exit smoke は `{}` ではなく `0` を使うのか。1 行で。
6. ROADMAP §17 の四ステップを守る目的は何なのか。1 行で。

---

## 12. 参照

- ROADMAP §2（Inviolable principles：P3 / P4 / P6 / A2 / A6）
- ROADMAP §9.5 / 3.8〜3.14（Phase 3 後半タスク）
- ROADMAP §13（rejected patterns：marker dict / `pub var`）
- ROADMAP §17（Amendment policy 全文）
- ADR 0001（macroexpand routing — 同じ「後から見えた決定」パターン
  の前例）
- ADR 0002（Phase 3 exit smoke が `{}` を使わない理由）
- `src/runtime/print.zig`（task 3.8 の成果）
- `src/eval/node.zig` / `src/eval/analyzer.zig`（task 3.9）
- `src/runtime/collection/ex_info.zig` / `src/lang/primitive/error.zig`
  （task 3.10）
- `src/eval/backend/tree_walk.zig`（task 3.11）
- `src/lang/bootstrap.zig` / `src/lang/clj/clojure/core.clj`
  （task 3.12 / 3.13）
- `src/lang/macro_transforms.zig::expandDefn`（task 3.13）
- `test/e2e/phase3_exit.sh`（task 3.14）

---

## 13. チェックリスト

- [ ] 演習 1.1 の `else` arm のフォーマットを即答できる
- [ ] 演習 2.1 の `buildTryBody` をシグネチャから書ける
- [ ] 演習 2.2 の arity エラー文を 1 行で説明できる
- [ ] 演習 3.1 の dangling slice 問題を Phase 5+ GC 視点で説明できる
- [ ] 演習 4.1 の closure 所有権を allocator 違いで説明できる
- [ ] 演習 4.2 の try/finally 実行順をトレースできる
- [ ] 演習 4.3 の `tree_walk.zig` 公開 API を骨子から書ける
- [ ] 演習 5.1 の startup chain（4 と 5）を即答できる
- [ ] 演習 6.1 の起動順入れ替え時の影響を説明できる
- [ ] 演習 7.1 の §17.2 四ステップを順に挙げられる
- [ ] Feynman 6 問を 1 行ずつで答えられる
- [ ] ROADMAP §9.5 / 3.8〜3.14 と §17 を即座に指せる

---

## 次へ

Phase 3 はここで閉幕します。`(defn f [x] (+ x 1)) (f 2)` と `(try
... (catch ExceptionInfo e ...))` が end-to-end で動くようになり、
Phase 5 までの長い旅程の最初の三合目に立ったところです。Phase 4 は
**user-defined macro 経路** を整備し、`(defmacro foo [...] ...)` を
Clojure 側で書けるようにします。これは 3.12 で `core.clj` を「拡張点
として残す」と決めた選択が初めて意味を持つ段階であり、Zig fast-path
と user macro が共存する dispatcher の優先順位制御がテーマになります。
3.13 で `defn` を Zig 化したのは、Phase 4 で `defmacro` が立ったとき
に `core.clj` 側へ移管する将来計画とつながっています。

第 21 章: Phase 4 — User-defined macro routing（予定）
