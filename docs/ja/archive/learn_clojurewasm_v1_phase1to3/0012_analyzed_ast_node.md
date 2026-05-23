---
chapter: 12
commits:
  - e04c290
related-tasks:
  - §9.4 / 2.4
related-chapters:
  - 0011
  - 0013
date: 2026-04-27
---

# 0012 — 解析後 AST: Node tagged union

> 対応 task: §9.4 / 2.4 / 所要時間: 60〜80 分

`Form` は Reader が吐き出す **生の表面構文木** です。`Node` は、
それを「symbol を Var ポインタや slot index に解決」「special form
を専用 struct に振り分け」したあとの **型付き AST** です。Form →
Node の境界で解析を終わらせ、バックエンド（TreeWalk / Phase 4 の
VM）のホットパスから HashMap lookup と文字列比較を **すべて追い出す**
のが、この章の動機です。

---

## この章で学ぶこと

- なぜ Form と Node を分けるか — ROADMAP §4.4「解析と評価の分離」
- `Node = union(enum)` の **10 variant** とそれぞれの責務
- 全 variant に `loc: SourceLocation` を持たせる理由 (P6 を end-to-end
  で守る) と `Node.loc()` の **`inline else => |n| n.loc`** イディオム
- Phase-2 が **closure capture を持たない** 理由 (Phase 3+ で
  `FnNode.captured: []Value` 追加予定)

---

## 1. なぜ Form と Node を分けるのか

`(let [x 1 y 2 z 3] (+ x y z))` を Form のまま eval すると、`x` /
`y` / `z` のたびに「local か?」「ns を引く」「Var を deref」と
HashMap lookup が **eval のたびに** 走ってしまいます。

ClojureWasm の方針は **「解析時の 1 回で全部やっておけ」**:

| 段階     | やること                                               |
|----------|--------------------------------------------------------|
| Reader   | 文字列 → Form                                         |
| Analyzer | Form → Node (symbol を slot index/Var pointer に解決) |
| Backend  | Node → Value (switch + 配列 index で完了)             |

バックエンドは
`switch (node.*) { .local_ref => |n| locals[n.index], ... }` の
1 行で値が取れます。HashMap も文字列比較も介在しません。

コスト差を具体的な数で見ると効果が分かります。`(let* [x 1] (+ x x))`
を 1000 回 eval する状況で、`(+ x x)` 内のシンボル参照は 3 回
(`+`, `x`, `x`)。Form を直接 walk する場合は **3 lookup × 1000 回 =
3000 lookup** が走ります。一方 Node 経由なら、解析時 1 回の 3 lookup
で symbol を slot index と Var pointer に解決済みなので、eval ループ
は配列 index アクセスだけ — トータルで **3 lookup** で済みます。
**約 1000 倍** の差で、再 eval が多いほど効きます。

---

## 2. `Node = union(enum)` — 10 variants

```zig
pub const Node = union(enum) {
    constant:   ConstantNode,
    local_ref:  LocalRef,
    var_ref:    VarRef,
    def_node:   DefNode,
    if_node:    IfNode,
    do_node:    DoNode,
    quote_node: QuoteNode,
    fn_node:    FnNode,
    let_node:   LetNode,
    call_node:  CallNode,
};
```

| variant    | 由来 Form                | 主フィールド                          | backend での扱い           |
|------------|--------------------------|---------------------------------------|----------------------------|
| constant   | `nil` / `true` / `42` 等 | `value: Value`                        | そのまま return            |
| local_ref  | let/fn 内の symbol       | `index: u16`                          | `locals[index]`            |
| var_ref    | global symbol            | `var_ptr: *const Var`                 | `var_ptr.deref()`          |
| def_node   | `(def name v)`           | `name`, `value_expr`                  | `Env.intern`               |
| if_node    | `(if c t e?)`            | `cond`, `then_branch`, `else_branch?` | 真偽分岐                   |
| do_node    | `(do f1 f2 ...)`         | `forms: []const Node`                 | 順次 eval、最後を return   |
| quote_node | `(quote x)`              | `quoted: Value`                       | そのまま return            |
| fn_node    | `(fn* [params] body)`    | `arity`, `params`, `body`, `has_rest` | `Function` を heap alloc   |
| let_node   | `(let* [k v ...] body)`  | `bindings: []Binding`, `body`         | binding ごとに slot に書く |
| call_node  | `(callee a b ...)`       | `callee: *Node`, `args: []Node`       | `vtable.callFn` 経由       |

`union(enum)` の利点：

- **網羅性チェック**: switch に `else` を書かなければ、コンパイラが
  全 variant のカバーを保証してくれます。新 variant を追加した際に
  backend で対応が漏れていれば、コンパイルが失敗します。
- **データ局所性**: variant struct がインラインで格納されるため、
  pointer indirection は 1 段で済みます。

10 variant の構成は **「リテラル 1 / 参照 2 / special form 6 / 呼び
出し 1」** という覚え方で頭に残ります — `constant`、`local_ref` /
`var_ref`、`def_node` / `if_node` / `do_node` / `quote_node` /
`fn_node` / `let_node`、そして `call_node` です。

---

## 3. 全 variant に `loc: SourceLocation` がある理由

各 struct の最後の行は `loc: SourceLocation = .{}`：

```zig
pub const ConstantNode = struct {
    value: Value,
    loc: SourceLocation = .{},
};

pub const IfNode = struct {
    cond: *const Node,
    then_branch: *const Node,
    else_branch: ?*const Node = null,
    loc: SourceLocation = .{},
};
```

ROADMAP §2 **原則 P6（Error quality is non-negotiable）** が要求する
「すべてのエラーに `<file>:<line>:<col>` を付ける」を end-to-end で
守るには、Tokenizer → Reader → **Analyzer（この章）** → Backend の
4 段のあいだで location が **欠落しない** 必要があります。`= .{}`
のデフォルトは `SourceLocation{}` なのでテストでは省略できますが、
本番の analyzer では必ず明示的に Form の location を渡します。

### `Node.loc()` と `inline else`

10 variant ぶんの switch arm を書く代わりに Zig 0.16 イディオム
`inline else` で 1 行に縮める：

```zig
pub fn loc(self: Node) SourceLocation {
    return switch (self) {
        inline else => |n| n.loc,
    };
}
```

「**残ったすべての variant について、capture `n` で同じ式を評価
する**」という意味です。コンパイラが variant ごとに inline 展開する
ので、ランタイム性能は手書きの 10 arm と同じ（O(1) jump）で、ソース
は 1 行で済みます。

これが効くのは、**全 variant が共通フィールド `loc` を持っているから**
です。1 つでも欠けると型が通りません。Zig の type system が「全
variant に loc を持たせる」というルールを **コードで強制してくれる**
わけです。仮に「全 variant が `kind_name: []const u8` を持つ」と
仮定すれば、`pub fn kindName(self: Node) []const u8` も
`return switch (self) { inline else => |n| n.kind_name }` の 1 行で
書けますが、1 つでも欠けた時点で `error: no field named 'kind_name'`
でコンパイルが落ちます。**構造的なルールを type system が守って
くれる** というのがこのイディオムの核心です。

---

## 4. `LocalRef` と `VarRef` — 解決済み参照

```zig
pub const LocalRef = struct {
    name: []const u8,    // debug + error message 用
    index: u16,          // slot index (analyzer が決定)
    loc: SourceLocation = .{},
};

pub const VarRef = struct {
    var_ptr: *const Var, // 解決済み Var ポインタ
    loc: SourceLocation = .{},
};
```

### `LocalRef.index` は backend と analyzer の契約

`(let* [x 1 y 2] (+ x y))` を analyse すると、`x → slot 0`、`y →
slot 1` となり、body の `x` 参照は `LocalRef{ name: "x", index: 0 }`
になります。**slot 番号は TreeWalk と将来の VM とで共有します**。
Phase 4 で VM が登場しても、analyzer の出力をそのまま再利用できる
ようになっています。

### `VarRef.var_ptr` の deref は dynamic binding 用

`(def x 1)` 後の `x` 参照は、analyzer が `*const Var` を resolve
済みの状態にしてあります。バックエンドは `var_ref.var_ptr.deref()`
を呼びます。**deref が必要な理由** は、`^:dynamic` Var の binding
stack override を Phase 3+ で拾えるようにするためです。Phase 2 では
`var_ptr.root` を返すだけですが、間接化を Day 1 から仕込んでおくこと
で、Phase 3 で拡張する際に backend を変更せずに済みます。

### `name` フィールドが残る理由

`LocalRef.name` は eval では使いません（`index` だけで十分）。残して
あるのは **エラーメッセージ** と **debug print** のためです。「ホット
パスでは使わないけれど、落ちたときには欲しい情報」を heap に置かず、
Node に inline 埋め込みする方針です。

---

## 5. 6 special form の Node struct

### `DefNode`

```zig
pub const DefNode = struct {
    name: []const u8,
    value_expr: *const Node,
    is_dynamic: bool = false,
    is_macro: bool = false,
    is_private: bool = false,
    loc: SourceLocation = .{},
};
```

`is_dynamic` などの flag は `(def ^:dynamic *foo*)` のような metadata
由来で、Phase 2 ではすべて false です。`env.zig` の `VarFlags` と
意味は同じですが、Node 側で再定義しています。Node tree が analyzer
の parsing context を import しないようにするための zone 規律で
あり、Phase 3+ で metadata 体系が固まった時点で一本化する予定です。

### `IfNode` / `DoNode` / `QuoteNode`

`IfNode.else_branch` は `?*const Node`（省略可）です。`DoNode.forms`
は `[]const Node`（ポインタではなく slice）です。`QuoteNode.quoted`
は **`Node` ではなく `Value`** で、analyse 時に reify 済みです。

### `FnNode` — Phase 2 では capture が無い

```zig
pub const FnNode = struct {
    arity: u16,
    has_rest: bool = false,
    params: []const []const u8,
    body: *const Node,
    loc: SourceLocation = .{},
};
```

- `arity`: 通常引数の数 (`& rest` 含まない)
- `params`: `has_rest` なら長さ `arity + 1` (rest 名が末尾)
- `body`: 単一 Node。複数 form は analyzer が `do_node` に畳む

#### Phase 2 の境界: closure capture なし

`FnNode` に `captured: []Value` フィールドが **ありません**。

```clojure
(let* [x 1] (fn* [y] (+ x y)))   ; ← Phase 2 では x が解決できない
```

このコードは body の `x` を見ようとしますが、Phase 2 の `Function`
は eval 時にしか locals を持たないため、生成された fn が呼ばれた
ときに `x` が読めません。

**Phase 2 で動く fn の範囲**:

- top-level の `(def f (fn* [x] x))` → OK
- `(fn* [x] (+ x 1))` の中で global Var の `+` を呼ぶ → OK
- `((fn* [x] x) 41)` → OK（fn を直接呼び出すケース）

Phase 3+ で `FnNode.captured: []Value` を追加し、analyzer が free
variable を集めて capture する予定です。

### `LetNode`

```zig
pub const LetNode = struct {
    bindings: []const Binding,
    body: *const Node,
    loc: SourceLocation = .{},

    pub const Binding = struct {
        name: []const u8,
        index: u16,
        value_expr: *const Node,
    };
};
```

`(let* [x 1 y 2] body)` → `bindings = [{x, 0, 1}, {y, 1, 2}]` + `body`
となります。**Clojure semantics**: `(let [x 1 y x] y)` の `y x` の
ほうの `x` は、直前の binding を見ます（analyzer が「value → declare」
順で処理しているため。第 13 章 §8 で扱います）。

### `CallNode`

```zig
pub const CallNode = struct {
    callee: *const Node,
    args: []const Node,
    loc: SourceLocation = .{},
};
```

汎用呼び出しです。`(f 1 2)` も `((fn* [x] x) 41)` もすべて call_node
に落ちます（callee が var_ref か fn_node かが違うだけです）。

---

## 6. メモリ ownership — Arena 一気開放

`Node` のフィールドはいずれも `*const Node` か `[]const Node`、
あるいは `[]const u8` です。**すべてが「同じ arena から取った参照」**
であることを前提にしています:

- `*const Node` は子が同じ arena
- `[]const Node` は `arena.alloc(Node, n)`
- `[]const u8` の name は `arena.dupe(...)`

eval が終わったら `arena.deinit()` で **一気に解放します**。Node を
個別に free しない設計です。

```
[arena]
├ Node{ .let_node }
│   ├ bindings (Binding 配列)        ← arena.alloc
│   │   └ value_expr (*Node) × N    ← arena.create
│   └ body (*Node)                   ← arena.create
```

**Node は Value ではない** ので、Phase 5 GC は Node を trace しま
せん。これが「map / vec literal は constant Value にリフトする」
「Node tree の中に Value を載せて GC を二重管理にしない」という
方針の根拠です。Node tree のライフサイクルは GC とは独立しています。

具体例として `(if true 1 2)` を analyse した場合の arena allocation
を眺めると、構造はこうなります：

```
arena allocations:
  [1] Node{ .if_node = .{
        .cond        = &[2],
        .then_branch = &[3],
        .else_branch = &[4],
      }}
  [2] Node{ .constant = .{ .value = true_val } }
  [3] Node{ .constant = .{ .value = initInteger(1) } }
  [4] Node{ .constant = .{ .value = initInteger(2) } }
```

`(if true 1)` のように else を省略すれば `[4]` は作られず
`else_branch = null`。最終的に `arena.deinit()` 1 発で全部解放され
ます。

---

## 7. 設計判断と却下した代替

| 案                                               | 採否 | 理由                                                  |
|--------------------------------------------------|------|-------------------------------------------------------|
| `union(enum)` 10 variant                         | ✓   | switch 網羅性 + cache locality + slot index 共有      |
| Form を直接 eval                                 | ✗   | HashMap lookup がホットパスに残る、§4.4 違反         |
| Node に `tag: Tag` + `extern union { ... }`      | ✗   | 網羅性チェックが効かず、Phase 4 VM 生成器でバグが出る |
| Node に `captured: []Value` を最初から           | ✗   | Phase 2 で使わないものは載せない (P3 / Day 1 minimal) |
| `loc` を別テーブル (NodeId → SourceLocation) に | ✗   | Phase 2 のサイズ感では inline 埋め込みのほうが単純    |

ROADMAP §4.4「解析と評価の分離」/ P3「コアは安定」/ P6「エラー
品質は譲れない」/ A6「1000 行以下」と整合。

---

## 8. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout e04c290
zig build test
# node.zig 単体のテスト 11 個が通る (Node.loc dispatches、
#   ConstantNode holds、IfNode optional else、FnNode default has_rest、
#   DoNode empty、LetNode binding、DefNode flag defaults、QuoteNode、
#   CallNode、LocalRef.index distinguishes...)

git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout cw-from-scratch
```

この時点では analyzer も backend もまだありません。テストでは Node
型の **構造上の不変条件** だけを確認しています（`Function` を呼ば
ない、値を返さない、といった範囲です）。

---

## 9. 教科書との対比

| 軸                        | v1 (`ClojureWasm`)        | v1_ref | Clojure JVM          | 本リポ                        |
|---------------------------|---------------------------|--------|----------------------|-------------------------------|
| Node ファイル行数         | 715                       | 244    | n/a (Java hierarchy) | **260**                       |
| variant 数 (Phase-2 相当) | ~30 (loop/recur/try 含む) | 11     | n/a                  | **10** (Phase-2 minimum)      |
| loc の持ち方              | inline                    | inline | `IFn` source meta    | **inline + `inline else`**    |
| symbol resolution         | 解析時 + macro            | 解析時 | 解析時 (`Compiler`)  | **解析時、macro は Phase 3+** |
| closure capture           | あり (ClosureNode)        | あり   | あり (`FnExpr`)      | **無し（Phase 3+）**          |

引っ張られずに本リポジトリの理念で整理した点：
- v1 は loop / recur / try / throw を最初から Node に含めて 30+
  variant になっていました。本リポジトリは **Phase 2 で動くもの
  だけ 10 variant** で打ち止めにしています。
- Clojure JVM は Java の class hierarchy（`IfExpr`、`LetExpr`、…）
  を採っています。Zig の `union(enum)` は switch の網羅性を type
  system で保証できる、より強い表現です。
- `inline else => |n| n.loc` は Zig 0.16 の新しいイディオムで、本
  リポジトリでも採用しています。

---

## この章で学んだこと

- 結局のところ、この章は **「解析時の 1 回で symbol を slot index と
  Var pointer に焼き込み、ホットパスから HashMap lookup と文字列
  比較を消し去る」** ための型を設計した話です。
- `union(enum)` の網羅性チェックと `inline else => |n| n.loc` は、
  **「全 variant が `loc` を持つ」というルールを型システムに守らせる**
  Zig 0.16 の表現力を使い切った例です。
- Phase 2 の Node は **closure capture を持たない** という境界を
  あえて引き、Phase 3+ で `FnNode.captured: []Value` を足すまで
  「Day 1 minimal」を貫きます。

---

## 次へ

第 13 章: [Analyzer — Form を Node に変換する](./0013_analyzer_form_to_node.md)

— 6 つの special form を `comptime StaticStringMap` で dispatch し、
`Scope` chain でローカル変数を slot に割り当てます。本リポジトリで
「処理系の心臓」と呼べる、最大級の章です。
