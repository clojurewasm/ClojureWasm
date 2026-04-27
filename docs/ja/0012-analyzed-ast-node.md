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

`Form` は Reader が吐く **生の表面構文木**。`Node` はそれを「symbol
を Var ポインタや slot index に解決」「special form を専用 struct に
振り分け」したあとの **型付き AST** です。Form → Node の境界で
解析を終わらせることで、backend (TreeWalk / Phase 4 の VM) のホット
パスから HashMap lookup と string compare を **全部追い出す** のが
この章の動機。

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

`(let [x 1 y 2 z 3] (+ x y z))` を Form のまま eval すると、`x` `y`
`z` のたびに「local か？」「ns を引く」「Var を deref」と HashMap
lookup が **eval のたびに** 走る。

ClojureWasm の方針は **「解析時の 1 回で全部やっておけ」**:

| 段階     | やること                                                       |
|----------|----------------------------------------------------------------|
| Reader   | 文字列 → Form                                                  |
| Analyzer | Form → Node (symbol を slot index/Var pointer に解決)          |
| Backend  | Node → Value (switch + 配列 index で完了)                      |

backend は `switch (node.*) { .local_ref => |n| locals[n.index], ... }`
の 1 行で値が取れる。HashMap も string compare も無い。

### 演習 12.1: Form と Node のコストを並べる (L1)

`(let* [x 1] (+ x x))` を 1000 回 eval すると、Form 直接 walk と Node
経由でそれぞれ何回 HashMap lookup が発生するか？（resolve を 1 lookup
と数える。）

<details>
<summary>答え</summary>

`(+ x x)` には 3 シンボル参照 (`+ x x`)。

- Form 直接: 3 lookup × 1000 回 = **3000 lookup**
- Node 経由: 解析 1 回ぶんの 3 lookup + 1000 回 eval は配列 index
  のみ → **3 lookup**

約 **1000 倍**の差。再 eval が多いほど効く。

</details>

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

| variant       | 由来 Form                | 主フィールド                              | backend での扱い         |
|---------------|---------------------------|-------------------------------------------|---------------------------|
| constant      | `nil` / `true` / `42` 等  | `value: Value`                            | そのまま return           |
| local_ref     | let/fn 内の symbol        | `index: u16`                              | `locals[index]`           |
| var_ref       | global symbol             | `var_ptr: *const Var`                     | `var_ptr.deref()`         |
| def_node      | `(def name v)`            | `name`, `value_expr`                      | `Env.intern`              |
| if_node       | `(if c t e?)`             | `cond`, `then_branch`, `else_branch?`     | 真偽分岐                  |
| do_node       | `(do f1 f2 ...)`          | `forms: []const Node`                     | 順次 eval、最後を return  |
| quote_node    | `(quote x)`               | `quoted: Value`                           | そのまま return           |
| fn_node       | `(fn* [params] body)`     | `arity`, `params`, `body`, `has_rest`     | `Function` を heap alloc  |
| let_node      | `(let* [k v ...] body)`   | `bindings: []Binding`, `body`             | binding ごとに slot に書く|
| call_node     | `(callee a b ...)`        | `callee: *Node`, `args: []Node`           | `vtable.callFn` 経由      |

`union(enum)` の利点：

- **網羅性チェック**: switch で `else` を書かなければコンパイラが
  全 variant カバーを保証。新 variant 追加時に backend が漏れたら
  コンパイル失敗
- **データ局所性**: variant struct がインライン格納、pointer
  indirection が 1 段で済む

### 演習 12.2: 10 variant を空で列挙 (L1)

何も見ずに、Node の 10 variant のタグ名を書いてみる。ヒント:
「リテラル 1 / 参照 2 / special form 6 / 呼び出し 1」とグループ化。

<details>
<summary>答え</summary>

```
リテラル系 (1):  constant
参照系 (2):      local_ref, var_ref
special form (6): def_node, if_node, do_node, quote_node, fn_node, let_node
呼び出し (1):    call_node
```

</details>

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

ROADMAP §2 **原則 P6 (Error quality is non-negotiable)** が要求する
「全エラーに `<file>:<line>:<col>` を付ける」を end-to-end で守るには:

Tokenizer → Reader → **Analyzer (この章)** → Backend の 4 段で
location が **欠落しない** 必要がある。`= .{}` のデフォルトは
`SourceLocation{}` なのでテストでは省略できるが、本番 analyzer は
必ず明示的に Form の location を渡す。

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

「**残った全 variant について capture `n` で同じ式を評価**」。
コンパイラが variant ごとに inline 展開、ランタイム性能は手書き 10
arm と同じ (O(1) jump)、ソースは 1 行。

これが効くのは **全 variant が共通フィールド `loc` を持つから**。
1 つでも欠けると型が通らない — Zig type system が「全 variant に loc
を持たせる」ルールを **コードで強制** してくれる。

### 演習 12.3: `inline else` でメソッドを書く (L2)

「全 variant が `kind_name: []const u8` を持つ」と仮定して
`pub fn kindName(self: Node) []const u8` を書く。

<details>
<summary>答え</summary>

```zig
pub fn kindName(self: Node) []const u8 {
    return switch (self) {
        inline else => |n| n.kind_name,
    };
}
```

「全 variant が共通 field を持つ」という前提が `inline else` を成立
させる。1 つでも欠けると `error: no field named 'kind_name'` で
コンパイルが落ちる — **構造的なルールを type system が守る**。

</details>

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

`(let* [x 1 y 2] (+ x y))` を analyse すると `x → slot 0`, `y →
slot 1`、body の `x` 参照は `LocalRef{ name: "x", index: 0 }`。
**slot 番号は TreeWalk と将来の VM で共有** する。Phase 4 で VM が
来ても analyzer の出力はそのまま再利用。

### `VarRef.var_ptr` の deref は dynamic binding 用

`(def x 1)` 後の `x` 参照は analyzer が `*const Var` を resolve 済。
backend は `var_ref.var_ptr.deref()` を呼ぶ。**deref が必要な理由** は
`^:dynamic` Var の binding stack override を Phase 3+ で拾うため。
Phase 2 では `var_ptr.root` を返すだけだが、間接化を Day 1 で確保する
ことで Phase 3 拡張時に backend が変わらない。

### `name` フィールドが残る理由

`LocalRef.name` は eval に使わない (`index` で十分)。残してあるのは
**エラーメッセージ** と **debug print** のため。「ホットパスでは使わ
ないが落ちた時に欲しい情報」を heap に置かず Node に inline 埋め込む
方針。

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

`is_dynamic` 等の flag は `(def ^:dynamic *foo*)` 等 metadata 由来で、
Phase 2 では all-false。`env.zig` の `VarFlags` と意味は同じだが、
Node 側で再定義 — Node tree が analyzer の parsing context を import
しない zone 規律のため。Phase 3+ で metadata 体系が固まったら一本化。

### `IfNode` / `DoNode` / `QuoteNode`

`IfNode.else_branch` は `?*const Node` (省略可)。`DoNode.forms` は
`[]const Node` (ポインタじゃなくスライス)。`QuoteNode.quoted` は
**`Node` ではなく `Value`** — analyse 時に reify 済。

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

`FnNode` に `captured: []Value` フィールドが **無い**。

```clojure
(let* [x 1] (fn* [y] (+ x y)))   ; ← Phase 2 では x が解決できない
```

このコードは body の `x` を見ようとするが、Phase 2 の `Function` は
eval 時にしか locals を持たないので、生成された fn が呼ばれるときに
`x` が読めない。

**Phase 2 で動く fn の境界**:

- top-level `(def f (fn* [x] x))` ← OK
- `(fn* [x] (+ x 1))` 内で global Var `+` 呼ぶ ← OK
- `((fn* [x] x) 41)` ← OK (fn 直接 call)

Phase 3+ で `FnNode.captured: []Value` を追加し、analyzer が
free variable を集めて capture する予定。

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

`(let* [x 1 y 2] body)` → `bindings = [{x,0,1}, {y,1,2}]` + `body`。
**Clojure semantics**: `(let [x 1 y x] y)` の `y x` の `x` は直前の
binding を見る (analyzer が「value → declare」順で処理、第 13 章 §8)。

### `CallNode`

```zig
pub const CallNode = struct {
    callee: *const Node,
    args: []const Node,
    loc: SourceLocation = .{},
};
```

汎用呼び出し。`(f 1 2)` も `((fn* [x] x) 41)` も全部 call_node に落ちる
(callee が var_ref か fn_node かが違うだけ)。

---

## 6. メモリ ownership — Arena 一気開放

`Node` のフィールドはいずれも `*const Node` か `[]const Node` か
`[]const u8`。**全部「同じ arena から取った参照」** が前提:

- `*const Node` は子が同じ arena
- `[]const Node` は `arena.alloc(Node, n)`
- `[]const u8` の name は `arena.dupe(...)`

eval が終わったら `arena.deinit()` で **一気開放**。Node は個別
free しない設計。

```
[arena]
├ Node{ .let_node }
│   ├ bindings (Binding 配列)        ← arena.alloc
│   │   └ value_expr (*Node) × N    ← arena.create
│   └ body (*Node)                   ← arena.create
```

**Node は Value ではない** ので、Phase 5 GC は Node を trace しない。
これが「map / vec literal は constant Value にリフトせよ」「Node tree
の中に Value を載せて GC を二重管理にしない」の理由。Node tree の
ライフサイクルは GC とは独立。

### 演習 12.4: `(if true 1 2)` のメモリレイアウト (L2)

analyse 結果の Node tree を arena 上のブロックとして書き起こす。

<details>
<summary>答え</summary>

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

`(if true 1)` だと `[4]` が作られず `else_branch = null`。
`arena.deinit()` 1 発で全部解放。

</details>

---

## 7. 演習 12.5: `Node` を再構成 (L3)

ファイル名と公開 API のリストだけを与える。

要求:
- File: `src/eval/node.zig`
- `pub const Node = union(enum) { ... 10 variants }`
- `pub fn loc(self: Node) SourceLocation` (`inline else` で実装)
- 各 variant の struct (field レベル)
- `LetNode.Binding` (name / index / value_expr)
- 制約: Phase 2 では `FnNode` に `captured` を含めない、全 variant
  最後に `loc: SourceLocation = .{}`、`DoNode.forms` と
  `CallNode.args` は `[]const Node`

<details>
<summary>答え骨子</summary>

```zig
//! Node — analyzer's typed AST.

const std = @import("std");
const Value = @import("../runtime/value.zig").Value;
const SourceLocation = @import("../runtime/error.zig").SourceLocation;
const Var = @import("../runtime/env.zig").Var;

pub const Node = union(enum) {
    constant: ConstantNode,
    local_ref: LocalRef,
    var_ref: VarRef,
    def_node: DefNode,
    if_node: IfNode,
    do_node: DoNode,
    quote_node: QuoteNode,
    fn_node: FnNode,
    let_node: LetNode,
    call_node: CallNode,

    pub fn loc(self: Node) SourceLocation {
        return switch (self) {
            inline else => |n| n.loc,
        };
    }
};

pub const ConstantNode = struct { value: Value, loc: SourceLocation = .{} };
pub const LocalRef = struct { name: []const u8, index: u16, loc: SourceLocation = .{} };
pub const VarRef = struct { var_ptr: *const Var, loc: SourceLocation = .{} };
pub const DefNode = struct {
    name: []const u8, value_expr: *const Node,
    is_dynamic: bool = false, is_macro: bool = false, is_private: bool = false,
    loc: SourceLocation = .{},
};
pub const IfNode = struct {
    cond: *const Node, then_branch: *const Node,
    else_branch: ?*const Node = null,
    loc: SourceLocation = .{},
};
pub const DoNode = struct { forms: []const Node, loc: SourceLocation = .{} };
pub const QuoteNode = struct { quoted: Value, loc: SourceLocation = .{} };
pub const FnNode = struct {
    arity: u16, has_rest: bool = false,
    params: []const []const u8, body: *const Node,
    loc: SourceLocation = .{},
};
pub const LetNode = struct {
    bindings: []const Binding, body: *const Node, loc: SourceLocation = .{},
    pub const Binding = struct { name: []const u8, index: u16, value_expr: *const Node };
};
pub const CallNode = struct {
    callee: *const Node, args: []const Node, loc: SourceLocation = .{},
};
```

検証: `zig build test` の `node.zig` テスト 11 個が通る。

</details>

---

## 8. 設計判断と却下した代替

| 案                                                | 採否 | 理由                                                          |
|---------------------------------------------------|------|---------------------------------------------------------------|
| `union(enum)` 10 variant                          | ✓    | switch 網羅性 + cache locality + slot index 共有              |
| Form を直接 eval                                  | ✗    | HashMap lookup がホットパスに残る、§4.4 違反                  |
| Node に `tag: Tag` + `extern union { ... }`       | ✗    | 網羅性チェックが効かず、Phase 4 VM 生成器でバグが出る         |
| Node に `captured: []Value` を最初から            | ✗    | Phase 2 で使わないものは載せない (P3 / Day 1 minimal)         |
| `loc` を別テーブル (NodeId → SourceLocation) に   | ✗    | Phase 2 のサイズ感では inline 埋め込みのほうが単純            |

ROADMAP §4.4「解析と評価の分離」/ P3「コアは安定」/ P6「エラー
品質は譲れない」/ A6「1000 行以下」と整合。

---

## 9. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout e04c290
zig build test
# node.zig 単体のテスト 11 個が通る (Node.loc dispatches、
#   ConstantNode holds、IfNode optional else、FnNode default has_rest、
#   DoNode empty、LetNode binding、DefNode flag defaults、QuoteNode、
#   CallNode、LocalRef.index distinguishes...)

git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout cw-from-scratch
```

この時点では analyzer も backend も無い。Node 型の **構造上の不変条件**
だけテストが確認している (`Function` を呼ばない、値を返さない)。

---

## 10. 教科書との対比

| 軸                       | v1 (`ClojureWasm`)            | v1_ref           | Clojure JVM         | 本リポ                   |
|--------------------------|-------------------------------|------------------|----------------------|--------------------------|
| Node ファイル行数        | 715                           | 244              | n/a (Java hierarchy) | **260**                  |
| variant 数 (Phase-2 相当)| ~30 (loop/recur/try 含む)     | 11               | n/a                  | **10** (Phase-2 minimum) |
| loc の持ち方             | inline                        | inline           | `IFn` source meta    | **inline + `inline else`**|
| symbol resolution        | 解析時 + macro                | 解析時           | 解析時 (`Compiler`)  | **解析時、macro は Phase 3+** |
| closure capture          | あり (ClosureNode)            | あり             | あり (`FnExpr`)      | **無し（Phase 3+）**     |

引っ張られず本リポの理念で整理した点：
- v1 は loop/recur/try/throw を最初から Node に含めて 30+ variant
  になっていた。本リポは **Phase 2 で動くものだけ 10 variant** で
  打ち止め
- Clojure JVM は Java class hierarchy (`IfExpr`, `LetExpr`, ...)。Zig
  の `union(enum)` は switch 網羅性を type system で保証する **より
  強い** 表現
- `inline else => |n| n.loc` は Zig 0.16 の新イディオム。本リポで採用

---

## 11. Feynman 課題

1. なぜ Form と Node を分けるの？ 1 行で。
2. なぜ全 variant に `loc` フィールドがあるの？ 1 行で。
3. Phase 2 の `FnNode` に何が「無い」の？ それはいつ追加される？

---

## 12. チェックリスト

- [ ] 演習 12.1: lookup 数の比較を予測できた
- [ ] 演習 12.2: 10 variant を空で列挙できた
- [ ] 演習 12.3: `inline else` で kindName を書けた
- [ ] 演習 12.4: `(if true 1 2)` のメモリレイアウトを描けた
- [ ] 演習 12.5: 公開 API リストだけから node.zig を書けた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout e04c290` で `zig build test` が緑

---

## 次へ

第 13 章: [Analyzer — Form を Node に変換する](./0013-analyzer-form-to-node.md)

— 6 special form を `comptime StaticStringMap` で dispatch、`Scope`
chain で local を slot に割当て。本リポで「処理系の心臓」と呼べる
最大の章です。
