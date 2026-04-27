---
chapter: 13
commits:
  - bb1459c
related-tasks:
  - §9.4 / 2.5
related-chapters:
  - 0012
  - 0014
date: 2026-04-27
---

# 0013 — Analyzer: Form を Node に変換する

> 対応 task: §9.4 / 2.5 / 所要時間: 90〜120 分

`Form` を受け取って `Node` を返す再帰下降のアナライザを扱う章です。
Phase 2 の **6 つの special form**（`def` / `if` / `do` / `quote` /
`fn*` / `let*`）の構文チェック、symbol を local slot か Var に解決
する処理、そして slot index の割り当てを **`Scope` chain** が担当
します。本リポジトリで「処理系の心臓」と呼べる、もっとも大きな
章です。

---

## この章で学ぶこと

- `analyze(arena, rt, env, scope, form) → !*const Node` の **5 引数の
  意味** と、なぜ scope を Optional にするか
- 6 special form を **`comptime StaticStringMap`** で dispatch
- `Scope` chain — `parent` ポインタ + `bindings` HashMap + `next_slot`
  の 3 フィールドで Clojure の lexical scope を表現
- name resolution の優先順 — **locals → mappings → refers**
- `let*` / `fn*` の **body 1 form は as-is、複数 form は `do_node` に
  畳む** という正規化
- `(quote x)` の Phase-2 制限：atom リテラルのみリフト、symbol/list は
  `error.NotImplemented`

---

## 1. シグネチャ — `analyze` の 5 引数

```zig
pub fn analyze(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    form: Form,
) AnalyzeError!*const Node;
```

| 引数    | 役割 |
|---------|------|
| `arena` | Node tree の置き場、1 解析で投げる全 Node が同じ arena に乗る |
| `rt`    | keyword interning に必要 (`:foo` を analyse 時に reify) |
| `env`   | global symbol を解決する namespace を引く |
| `scope` | local-binding chain。**top-level では `null`**、`let*`/`fn*` 内で `*const Scope` |
| `form`  | analyse 対象の Form |

```zig
pub const AnalyzeError = error{
    SyntaxError,    // 構文不正 (例: (if 1 2 3 4))
    NameError,      // symbol が解決できない
    NotImplemented, // Phase 3+ の機能
    OutOfMemory,
};
```

`scope` が Optional な理由：top-level の `(def x 1)` は外側に何も無い
ので chain 起点の null が必要。`let*` / `fn*` に入ると child scope
を作って渡す。

### `analyze` 本体 — Form variant ごとに dispatch

```zig
return switch (form.data) {
    .nil       => try makeConstant(arena, .nil_val, form),
    .boolean   => |b| try makeConstant(arena, if (b) .true_val else .false_val, form),
    .integer   => |i| try makeConstant(arena, Value.initInteger(i), form),
    .float     => |f| try makeConstant(arena, Value.initFloat(f), form),
    .keyword   => |sym| {
        const v = try keyword.intern(rt, sym.ns, sym.name);
        return try makeConstant(arena, v, form);
    },
    .symbol => |sym| try analyzeSymbol(arena, env, scope, sym, form),
    .list   => |items| try analyzeList(arena, rt, env, scope, items, form),
    .string, .vector, .map => return AnalyzeError.NotImplemented,
};
```

atom 5 種は Value に reify して `ConstantNode` に詰める (`keyword`
だけ interner 経由で同一 bit pattern を保証)。string / vector / map
は **Phase 3+**: heap-backed Value 表現が必要 (Phase 5 で来る)。
silent failure を避けるため `NotImplemented` 明示。

### 演習 13.1: atom の reify を予測 (L1)

`(if true 42 :foo)` を analyse すると、何個の `ConstantNode` が
arena に作られるか？

<details>
<summary>答え</summary>

3 個 (cond:`true`, then:`42`, else:`:foo`) + 外側 `IfNode` 1 個 =
合計 4 alloc。`:foo` は intern を経由するので別の場所で再 analyse
しても同じ Value bit pattern が返る (identity 比較が定数時間)。

</details>

---

## 2. `Scope` chain — lexical scope の表現

```zig
pub const Scope = struct {
    parent: ?*const Scope = null,
    bindings: std.StringHashMapUnmanaged(u16) = .empty,
    next_slot: u16 = 0,

    pub fn child(parent: *const Scope) Scope {
        return .{ .parent = parent, .next_slot = parent.next_slot };
    }
    pub fn declare(self: *Scope, alloc: std.mem.Allocator, name: []const u8) !u16 {
        const slot = self.next_slot;
        try self.bindings.put(alloc, name, slot);
        self.next_slot += 1;
        return slot;
    }
    pub fn lookup(self: *const Scope, name: []const u8) ?u16 {
        if (self.bindings.get(name)) |idx| return idx;
        if (self.parent) |p| return p.lookup(name);
        return null;
    }
};
```

### `next_slot` を child に **継承** する理由

`(let* [x 1] (let* [y 2] (+ x y)))` で外側 `x → slot 0`、内側 `y →
slot 1`。**slot 0 を再利用しない** のは、TreeWalk backend が
**1 つの flat な locals 配列** に全 local を載せるから。同じ slot
を 2 つの local が共有すると内側の binding が外側を上書きする。
shadowing (`(let* [x 1] (let* [x 2] x))`) は自動でハンドルされる:
内側 `x` は slot 1 に新規エントリ、外側 `x` は slot 0 に居続けるが
内側スコープからは見えない。

### 演習 13.2: `lookup` を loop で書き換える (L2)

再帰版を while loop で書き直す。

```zig
pub fn lookup(self: *const Scope, name: []const u8) ?u16 {
    // ここから書く
}
```

ヒント: `var s: ?*const Scope = self;` から `while (s) |cur| { ... }`。

<details>
<summary>答え</summary>

```zig
pub fn lookup(self: *const Scope, name: []const u8) ?u16 {
    var s: ?*const Scope = self;
    while (s) |cur| {
        if (cur.bindings.get(name)) |idx| return idx;
        s = cur.parent;
    }
    return null;
}
```

再帰と動作は等価。Phase 4 で hot path に来たら loop 版に書き換える
価値あり。

</details>

---

## 3. Symbol 解決 — locals → mappings → refers

```zig
fn analyzeSymbol(...) AnalyzeError!*const Node {
    if (sym.ns == null and scope != null) {
        if (scope.?.lookup(sym.name)) |slot| {
            // → LocalRef を作って返す
        }
    }
    const ns = if (sym.ns) |ns_name|
        env.findNs(ns_name) orelse return AnalyzeError.NameError
    else
        env.current_ns orelse return AnalyzeError.NameError;
    const v_ptr = ns.resolve(sym.name) orelse return AnalyzeError.NameError;
    // → VarRef を作って返す
}
```

**Clojure 仕様** の 3 段:

1. **locals** ← `scope.lookup(name)` (HashMap chain walk)
2. **current namespace の mappings** ← `(def name v)` で intern 済 var
3. **current namespace の refers** ← `(refer 'rt)` 等で他 ns から引いた var

(2)+(3) を `Namespace.resolve()` がまとめて返す。`sym.ns` が non-null
(qualified) なら **locals は飛ばして** `findNs` する — `(let* [foo 1]
foo/bar)` は qualified なので locals 検索しない。

### 演習 13.3: 5 種類の symbol 解決を予測 (L1)

仮定: `user` ns に `+` が intern 済、`scope` で `a → slot 0`。

```
1. (analyze a)              → ?
2. (analyze +)              → ?
3. (analyze user/+)         → ?
4. (analyze missing)        → ?
5. (analyze missing/x)      → ?
```

<details>
<summary>答え</summary>

| symbol      | 解決結果                                         |
|-------------|--------------------------------------------------|
| `a`         | **LocalRef** (slot 0)                            |
| `+`         | **VarRef** (user ns)                             |
| `user/+`    | **VarRef** (qualified、locals 飛ばし)            |
| `missing`   | `error.NameError`                                |
| `missing/x` | `error.NameError` (`missing` ns が無い)          |

`user/a` のように qualified で local 名を書いても **locals は無視**
される (Clojure 仕様)。

</details>

---

## 4. List dispatch — special form と call の振り分け

```zig
fn analyzeList(...) AnalyzeError!*const Node {
    if (items.len == 0) return AnalyzeError.NotImplemented;  // 空リスト
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(arena, rt, env, scope, kind, items, form);
            }
        }
    }
    return analyzeCall(arena, rt, env, scope, items, form);
}
```

順序: (1) 空リスト `()` → `NotImplemented` (heap List 必要、Phase 5)、
(2) 先頭が **unqualified** symbol で special form 名に一致 →
`analyzeSpecial`、(3) それ以外 → `analyzeCall`。これにより
`(my-ns/if 1 2 3)` は **ただの call** として扱われる (Clojure 慣習)。

### `comptime StaticStringMap` — 6 special form の dispatch

```zig
const SpecialFormKind = enum { def, if_form, do_form, quote_form, fn_star, let_star };

const SPECIAL_FORMS = std.StaticStringMap(SpecialFormKind).initComptime(.{
    .{ "def", .def },
    .{ "if", .if_form },
    .{ "do", .do_form },
    .{ "quote", .quote_form },
    .{ "fn*", .fn_star },
    .{ "let*", .let_star },
});
```

**comptime に perfect-hash table 構築**、runtime lookup は memcmp +
配列 index 数命令。`if-else` chain は O(N)、`runtime HashMap` は
hash + bucket walk + alloc。`StaticStringMap` は **O(1)、alloc 0**。

### 演習 13.4: 大文字 IF を analyse すると (L1)

`(IF cond t e)` (大文字) の挙動は？

<details>
<summary>答え</summary>

`SPECIAL_FORMS.get("IF")` は `null` (小文字 `if` のみ登録) →
`analyzeCall` に進む → `IF` という Var を resolve (無ければ NameError)。

Clojure の **大文字小文字を区別する** 性質と一致。`IF` を関数として
定義すれば呼べる、`if` を再 def しても special form 解釈が優先
(special form は env 引く前に判定)。

</details>

---

## 5. `def` / `if` / `do` の analyser

### `(def name)` / `(def name value)`

```zig
fn analyzeDef(...) AnalyzeError!*const Node {
    if (items.len < 2 or items.len > 3) return AnalyzeError.SyntaxError;
    if (items[1].data != .symbol) return AnalyzeError.SyntaxError;
    const name_sym = items[1].data.symbol;
    if (name_sym.ns != null) return AnalyzeError.SyntaxError;
    const value_node = if (items.len == 3)
        try analyze(arena, rt, env, scope, items[2])
    else
        try makeConstant(arena, .nil_val, items[1]);
    ...
}
```

- 引数 1〜2 個。`(def x)` は `nil` がデフォルト
- `name` は **unqualified**。`(def my.ns/x 1)` は SyntaxError

### `(if cond then)` / `(if cond then else)`

引数 2〜3 個、else 省略可 (不在なら `else_branch = null`)。
`(if 1 2 3 4)` は SyntaxError。

### `(do f1 f2 ...)`

```zig
var forms = try arena.alloc(Node, items.len - 1);
for (items[1..], 0..) |f, i| {
    const sub = try analyze(arena, rt, env, scope, f);
    forms[i] = sub.*;   // Node 値コピーでスライスに格納
}
```

`(do)` 空 do は `forms.len = 0` → backend で `nil_val` 返却。

---

## 6. `(quote x)` — Phase 2 の atom-only 制限

```zig
fn formToValue(rt: *Runtime, form: Form) AnalyzeError!Value {
    return switch (form.data) {
        .nil       => .nil_val,
        .boolean   => |b| if (b) .true_val else .false_val,
        .integer   => |i| Value.initInteger(i),
        .float     => |f| Value.initFloat(f),
        .keyword   => |sym| try keyword.intern(rt, sym.ns, sym.name),
        .symbol, .string, .list, .vector, .map => AnalyzeError.NotImplemented,
    };
}
```

`(quote x)` は **atom 5 種のみ** Value にリフトできる。`(quote
some-symbol)` `(quote (1 2 3))` `(quote "hello")` `(quote [1 2 3])`
は heap-backed Value 必要 (Phase 5)。silently 通すのではなく
**明示的に error**:

```zig
try testing.expectError(AnalyzeError.NotImplemented, fix.analyzeStr("(quote x)"));
```

「いつか動く」コードと「今すぐ通る」エラーを区別する方針。silent
NaN なら debug 不可能。

---

## 7. `(fn* [params] body...)` — slot 0..N-1 への割当て

Phase 2 最大の analyser ロジック。`analyzeFnStar` の流れは 4 step:

1. **params vector を構文チェック + 名前抽出** — `&` を見つけたら
   次の 1 個を rest 名として記録、break
2. **child scope を作って slot 0..N-1 に declare** —
   `Scope.child(parent)` で `next_slot` を継承 (top-level なら
   `Scope{}` で 0 開始)
3. **body を analyse** — `analyzeBody` ヘルパ (1 form は as-is、
   複数なら do 畳み)
4. **`params` を arena に dupe** — `ArrayList` 解放後も生き続ける
   不変スライスを作る

```zig
var i: usize = 0;
while (i < params_form.len) : (i += 1) {
    if (params_form[i].data != .symbol) return AnalyzeError.SyntaxError;
    const ps = params_form[i].data.symbol;
    if (ps.ns != null) return AnalyzeError.SyntaxError;
    if (std.mem.eql(u8, ps.name, "&")) {
        if (i + 1 >= params_form.len) return AnalyzeError.SyntaxError;
        try param_names.append(arena, params_form[i + 1].data.symbol.name);
        has_rest = true;
        break;
    }
    try param_names.append(arena, ps.name);
    arity += 1;
}

var child_scope = if (scope) |s| Scope.child(s) else Scope{};
for (param_names.items) |name| {
    _ = try child_scope.declare(arena, name);
}
const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form);
```

`(fn* [x y & rest] body)` の結果: `arity=2`, `has_rest=true`,
`param_names=["x", "y", "rest"]` (rest 含む長さ 3)。

### 演習 13.5: `(fn* [x y] x)` のslot 割当て (L1)

`x` は slot 何番、`y` は slot 何番、body の `x` の `LocalRef.index`
は何？

<details>
<summary>答え</summary>

- `x` ← slot 0、`y` ← slot 1
- body の `x` ← `LocalRef.index = 0`
- `arity = 2`, `has_rest = false`, `params = ["x", "y"]`

backend は `args` を `locals[0..arity]` にコピーして body を eval。
body の `LocalRef.index = 0` なので `locals[0]` (= args[0]) が返る。

</details>

---

## 8. `(let* [k v ...] body)` — 値→宣言の順序

```zig
while (fi < binding_forms.len) : (fi += 2) {
    const name_sym = binding_forms[fi].data.symbol;
    // 「値 → 宣言」の順序が重要 (Clojure semantics)
    const value_node = try analyze(arena, rt, env, &child_scope, binding_forms[fi + 1]);
    const slot = try child_scope.declare(arena, name_sym.name);
    bindings[bi] = .{ .name = name_sym.name, .index = slot, .value_expr = value_node };
    bi += 1;
}
const body_node = try analyzeBody(arena, rt, env, &child_scope, items[2..], form);
```

### Clojure binding semantics — sequential

「値 → 宣言」の **順序** が重要。Clojure の `let` は **sequential**:
前の binding は次の binding から見えるが、各 value はその binding
自身の名前が宣言される **前** に評価される。

```clojure
(let* [x 1
       y x]      ; ← 右辺 x は外側の x を見る
  y)
```

- `x = 1` を analyse: 外側 scope に `x` 無し → NameError
- `x` を declare → slot 0
- `y = x` を analyse: child_scope に `x` あり → `LocalRef{ slot: 0 }`
- `y` を declare → slot 1
- body の `y` を analyse → `LocalRef{ slot: 1 }`

もし「値→宣言」を逆にすると、`(let* [x x] x)` の右辺 `x` が **自分
自身を参照** して未初期化 slot を読む UB。Clojure の `letfn`
(相互参照) とは別物 (Phase 2 では未対応)。

### 演習 13.6: `(let* [x 1 y 2] x)` の Node tree を予測 (L2)

<details>
<summary>答え</summary>

```
LetNode {
  bindings: [
    Binding { name: "x", index: 0, value_expr: → ConstantNode { 1 } }
    Binding { name: "y", index: 1, value_expr: → ConstantNode { 2 } }
  ],
  body: → LocalRef { name: "x", index: 0 }
}
```

`y` が slot 1 なのは `next_slot` 継承、body の `x` が `index=0` なのは
`child_scope.lookup("x")` がヒット。

</details>

---

## 9. `analyzeBody` と `analyzeCall`

`analyzeBody` は `fn*` / `let*` の body 用ヘルパで、**1 form は as-is、
複数なら `do_node` に畳む**:

| 入力 body                            | 結果                                |
|--------------------------------------|-------------------------------------|
| `(fn* [x] x)`                        | body = `LocalRef` 直                |
| `(fn* [x] (println x) x)`            | body = `DoNode { [println, x] }`    |
| `(let* [x 1] x)`                     | body = `LocalRef` 直                |
| `(let* [x 1] (do-thing) x)`          | body = `DoNode { [...] }`           |

`LetNode.body` も `FnNode.body` も **単一 Node** 型なので、このラップ
で型を合わせる。

`analyzeCall` は callee と args をそれぞれ analyse して `CallNode` に
詰めるだけ。callee は何でも来る (var_ref / fn_node / call_node)。
`((fn* [x] x) 41)` の結果:

```
CallNode {
  callee: → FnNode { arity: 1, params: ["x"], body: LocalRef{slot:0} }
  args: [Node{ ConstantNode{ value: 41 } }]
}
```

これが Phase 2 exit criterion の片方を構造的に達成する形。

---

## 10. 設計判断と却下した代替

| 案                                                              | 採否 | 理由                                                |
|-----------------------------------------------------------------|------|-----------------------------------------------------|
| 6 special form を `comptime StaticStringMap` で dispatch        | ✓    | comptime perfect-hash、O(1)、追加が表 1 行          |
| 5 引数 (`arena, rt, env, scope, form`)                          | ✓    | 関心の分離。scope を Optional で top-level 再帰     |
| `Scope.next_slot` を child に継承                               | ✓    | flat locals 配列を実現、shadowing も正しく動く      |
| Phase 2 で macro 展開                                           | ✗    | 後 phase。`SPECIAL_FORMS` に macro keyword 入れない |
| Vector / Map literal を式値として OK                            | ✗    | heap-backed Value 必要 (Phase 5)、`NotImplemented` |
| value→declare 順 (Clojure semantics)                            | ✓    | 仕様一致。逆順だと自己参照 UB                       |
| body 1 form を do に包まない                                    | ✓    | 無駄を省く。複数だけ `do_node` にラップ             |

ROADMAP §4.4 (解析と評価の分離), §2 P3 (コア安定), P6 (エラー品質)
と整合。「変更しないなら enum、増えうるなら StaticStringMap」が
Zig 0.16 の流儀。

---

## 11. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout bb1459c
zig build test
# analyzer.zig のテスト 14 個がすべて緑 (atoms / unbound NameError /
# resolved var_ref / if / do / quote / let* / nested shadows / fn* /
# fn* with rest / def / SyntaxError on (if 1 2 3 4) / Var-resolved call /
# direct fn-literal call ((fn* [x] x) 41))
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout cw-from-scratch
```

この時点では analyzer は完成していますが、TreeWalk backend がまだ
ないので **「Form を analyse して Node を返す」だけ** です。次章で
eval が登場します。

---

## 12. 教科書との対比

| 軸                | v1            | v1_ref     | Clojure JVM             | 本リポジトリ                      |
|-------------------|---------------|------------|-------------------------|-----------------------------|
| 行数              | 4070          | 746        | ~4000 (`Compiler.java`) | **677**                     |
| special form 数   | 18+           | 11         | 16                      | **6 (Phase-2 minimum)**     |
| Scope chain       | parent + Map  | 同じ       | LocalBinding 連結       | **parent + Map + next_slot**|
| name resolution   | locals→ns     | 同じ       | ditto                   | **locals → mappings → refers**|
| dispatch          | if-else       | 同じ       | enum (Java)             | **`StaticStringMap`**       |
| body 単一 form    | DoExpr 必須   | 包まない   | BodyExpr 必須           | **包まない**                |

引っ張られずに本リポジトリの理念で整理した点：
- v1 / Clojure JVM は **18+ の special form** を analyser に内蔵
  していましたが、Phase 2 はまず **6 つの form を動かす** ところに
  絞っています（loop / recur / try / throw は Phase 3+）。
- v1 は body を必ず DoExpr に包んでいましたが、本リポジトリは **1 form
  ならそのまま返します**。
- `comptime StaticStringMap` は Zig 0.16 の機能です。v1 が書かれた
  当時は if-else chain でした。

---

## 13. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. なぜ `let*` は **値を先に analyse して、宣言を後にする** のか。
   1 行で。
2. `Scope.child` で `next_slot` を継承するのはなぜか。1 行で。
3. `(quote x)` で symbol が `NotImplemented` になり、atom リテラルが
   通るのはなぜか。1 行で。

---

## 14. チェックリスト

- [ ] 演習 13.1: `ConstantNode` 数を予測できた
- [ ] 演習 13.2: `lookup` を loop 版で書けた
- [ ] 演習 13.3: 5 種類の symbol 解決を予測できた
- [ ] 演習 13.4: 大文字 IF の挙動を説明できた
- [ ] 演習 13.5: `(fn* [x y] x)` の slot 割当てを言える
- [ ] 演習 13.6: `(let* [x 1 y 2] x)` の Node tree を描けた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout bb1459c` で `zig build test` の analyzer 14 個が緑

---

## 次へ

第 14 章: [TreeWalk backend — Node を Value に評価する](./0014-tree-walk-evaluator.md)

— `Function` heap struct、`recur` 用 threadlocal pending signal、
`installVTable` での backend 注入、48-bit pointer による `builtin_fn`
表現と、**Phase 2 の処理系がついに走る瞬間** を見ていきます。
