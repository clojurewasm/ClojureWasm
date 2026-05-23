---
chapter: 19
commits:
  - 6630cbe
related-tasks:
  - §9.5/3.7
related-chapters:
  - 18
  - 20
date: 2026-04-27
---

# 19 — Macroexpand routing と ADR 0001

> 対応 task: §9.5 / 3.7 / 所要時間: ~60 分

3.7 は **マクロ展開を ClojureWasm v2 のどの層で行うか** を決め切る章です。
旧来の `Runtime.vtable.expandMacro` slot を **撤去** し、Layer-1 の
`eval/macro_dispatch.Table` 経由で `lang/macro_transforms.zig` の 9 個の
Zig 変換を呼ぶ設計に切り替えます。決定の経緯は ADR 0001
（`.dev/decisions/0001_macroexpand_routing.md`）に書き出してあります。

---

## この章で学ぶこと

- マクロ展開が「analyse の一部」であって「backend の責務」ではない理由
  （Phase 8+ dual-backend `--compare` との整合）
- `zone_deps` の制約下で Layer 1 → Layer 2 を呼ぶ正しい IoC パターン
  （vtable / DI / `pub var` のどれを選ぶかの判断軸）
- Form-level macro と Value-level macro の境界が **user `defmacro`
  invocation 1 箇所だけ** に局所化される設計
- `(let [x 1] (+ x 2))` が `(let* [x 1] (+ x 2))` に書き換わり、再
  analyse loop で安定するまでのトレース
- `(and 1 2 3)` が gensym + `let*` + `if` に展開される hygiene の仕組み

---

## 1. なぜ "vtable.expandMacro" を撤去したのか

Phase 1.2 / 2.1 段階で、`Runtime.vtable` は次のように定義されていました。

```zig
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
    expandMacro: ExpandMacroFn,    // ← 3.7 で削除
};
```

`expandMacro` は TreeWalk が install するスタブで、`error.NotImplemented`
を返すだけでした。3.7 で実装するときに「このスタブを育てる」のが直感
ですが、そこには 3 つの欠陥があります。

第 1 に、Phase 8+ で VM backend が来たとき、同じ実装を VM 側にも
install することになります。マクロ展開は backend 非依存（Form → Form の
純粋な syntax 変換）であって、TreeWalk と VM が同じ Node tree を消費
できなければ ROADMAP P12 に違反します。`callFn` は **backend ごとに
違う実装が必要** なので vtable に残す価値がありますが、`let → let*` の
rewrite は TreeWalk でも VM でも同一であり、backend と結びつける必然が
ありません。

第 2 に、`runtime/dispatch.VTable` は Layer 0 にあり、Form 型を参照
できません（Form は `eval/form.zig` = Layer 1）。マクロを Form-level で
運ぶには signature を Value-level にせざるを得ず、Form↔Value 全往復を
強要します。

第 3 に、`Runtime` がマクロを知っているように見えます。Layer 0 の
interface が膨らむと、テスト用の minimal Runtime や将来の embedder
（Wasm component pod）が不要な依存を背負います。

3 点とも「設計の意図に対する誤った場所」を示しています。ADR 0001 は
これを **slot 撤去 + Layer-1 dispatcher 新設** で解きました。

```zig
// 改訂後の VTable（縮小）
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
};
```

`expandMacro` の責務は `eval/macro_dispatch.zig` に移り、
`lang/macro_transforms.zig` がそこへ implementation を注入します。
将来 `(macroexpand-1 form)` を primitive として実装するときも、backend に
何も install する必要はありません。既存の `expandIfMacro` を Value→Value の
builtin として叩くだけで済みます。

---

## 2. Layer 1 の MacroTable と DI

`zone_deps.md` は Layer 1 (`eval/`) → Layer 2 (`lang/`) の direct
import を禁じます。`analyzer.zig` から `lang/macro_transforms` を直接
呼ぶことはできません。よって IoC が要ります。検討した 5 案は次の通りです。

| 案                                                                | 形                   | 採否 | 主な却下理由                        |
|-------------------------------------------------------------------|----------------------|------|-------------------------------------|
| A: analyzer から lang を直接 import                               | upward import        | ✗   | zone_deps 違反                      |
| B: `Runtime.vtable.expandMacro` を維持、impl を lang から install | Layer 0 vtable       | ✗   | Form↔Value 強制 / Layer 0 責務逸脱 |
| C: TreeWalk が macro 経路を所有                                   | backend coupling     | ✗   | P12 dual-backend 違反               |
| D: Reader と Analyzer の間に独立 macroexpand pass                 | full pre-pass        | ✗   | lexical shadowing が解けない        |
| E: `pub var registry` (eval/macro_dispatch)                       | module-level mutable | ✗   | `pub var` 禁止（zone_deps Guard 3） |
| F (採用): MacroTable を analyze の引数で threading                | DI                   | ✓   | 全制約クリア                        |

案 D の「独立 pass」が却下されたのは、`(let [foo macro-name] ...)` の
ような lexical shadowing が解けないためです。analyse 中の env-aware な
解決が必須なので、独立 pass ではなく analyse の inline サブステップに
する必要があります。

採用案 F の core はこうなります。

```zig
// eval/macro_dispatch.zig (Layer 1)
pub const ZigExpandFn = *const fn (
    arena: std.mem.Allocator,
    rt: *Runtime,
    args: []const Form,
    loc: SourceLocation,
) ExpandError!Form;

pub const Table = struct {
    entries: std.StringHashMapUnmanaged(ZigExpandFn) = .empty,
    alloc: std.mem.Allocator,
    pub fn init(alloc: std.mem.Allocator) Table {
        return .{ .alloc = alloc };
    }
    pub fn deinit(self: *Table) void {
        self.entries.deinit(self.alloc);
    }
    pub fn register(self: *Table, name: []const u8, f: ZigExpandFn) !void {
        const gop = try self.entries.getOrPut(self.alloc, name);
        std.debug.assert(!gop.found_existing);
        gop.value_ptr.* = f;
    }
    pub fn lookup(self: *const Table, name: []const u8) ?ZigExpandFn {
        return self.entries.get(name);
    }
};

pub fn expandIfMacro(
    arena, rt, env, table, head_var, head_name, args, loc,
) ExpandError!?Form { ... }
```

`std.StringHashMapUnmanaged` は per-call で `alloc` を渡す API です。
Table 自身が `.alloc` を保持するのは、呼び側が毎回 allocator を覚えなくて
済むようにするファサードです。`register` は `getOrPut` で lookup と
insert を 1 回の hash で済ませ、重複登録は `std.debug.assert` で
fail-fast にします（プログラマのバグ）。`name` は borrow（lang 側の
string literal を想定）であり、Table の lifetime が main.zig 内に
収まる前提で安全に運用できます。

そして analyzer の signature が変わります。

```zig
pub fn analyze(
    arena: std.mem.Allocator,
    rt: *Runtime,
    env: *Env,
    scope: ?*const Scope,
    form: Form,
    macro_table: *const macro_dispatch.Table,    // ← 追加
) AnalyzeError!*const Node { ... }
```

`macro_table` は `main.zig` で 1 回だけ構築され、loop 内で使い回されます。

```zig
var macro_table = macro_dispatch.Table.init(gpa);
defer macro_table.deinit();
try macro_transforms.registerInto(&env, &macro_table);

while (true) {
    // ...
    const node = analyzeForm(arena, &rt, &env, null, form, &macro_table)
        catch |err| { ... };
    // ...
}
```

鍵は **「workaround を作らない」** ことです。`macro_table: ?*const Table
= null`（nullable で既存呼び出しと互換）にしたくなる誘惑がありますが、
それでは新旧 2 経路が並走して mental model が分裂します。signature
変更は **全 11 callsite を一度に書き換える surgical edit** としました
（ROADMAP P3）。

---

## 3. analyzeList の macro 検出経路

`analyzeList` は次の優先順位で list を分類します。

```zig
fn analyzeList(arena, rt, env, scope, items, form, macro_table) ... {
    if (items.len == 0) { ... }              // (1) 空リスト
    if (items[0].data == .symbol) {
        const head = items[0].data.symbol;
        if (head.ns == null) {
            if (SPECIAL_FORMS.get(head.name)) |kind| {
                return analyzeSpecial(...);  // (2) 特殊形式が最優先
            }
        }
        // (3) local が macro を shadow していないかチェック
        if (head.ns == null and scope != null and scope.?.lookup(head.name) != null) {
            // shadowed: not a macro
        } else {
            // (4) macro 経路
            if (resolveMaybe(env, head)) |v_ptr| {
                if (try macro_dispatch.expandIfMacro(
                    arena, rt, env, macro_table,
                    v_ptr, head.name, items[1..], form.location,
                )) |expanded| {
                    return analyze(arena, rt, env, scope, expanded, macro_table);
                    //                                              ↑
                    //                  expanded form を再 analyse
                }
            }
        }
    }
    return analyzeCall(...);                 // (5) ふつうの function call
}
```

ポイントを整理します。

**(2) 特殊形式が macro より先**。ユーザが `(def let ...)` で macro Var
を上書きしても、`let*` などの special form 解析は常に勝ちます。Clojure
JVM `Compiler.java` も同じ regulation です。

**(3) local が macro を shadow する**。`(let [if 99] (if 1 2 3))` では
inner `(if 1 2 3)` の head `if` が special form なので macro 経路に
入りません（special form チェック (2) で勝つ）が、もし special form でない
macro 名（`when` など）を local で shadow すると、`scope.lookup` ヒットで
macro 経路をスキップします。具体例を表で確認します。

| 入力                                                     | 入る枝                                                                                         |
|----------------------------------------------------------|------------------------------------------------------------------------------------------------|
| `(quote (1 2 3))`                                        | (2) special form `quote`                                                                       |
| `(when true 42)`                                         | (4) macro `when` を expand                                                                     |
| `(let [if 99] if)` の inner `if`                         | symbol だが list ではない、analyzeSymbol 経路                                                  |
| `(let [when 99] (when true 1))` の inner `(when true 1)` | (3) local `when` shadow → (5) ふつうの call として処理（local Var への call、結果は型エラー） |
| `(+ 1 2)`                                                | (5) ふつうの call。`+` は special でも macro でもなく builtin_fn                               |

local が macro 名を shadow すると **macro が切られる** という挙動は
ユーザコードに優しい一方で混乱の元でもあります。Clojure コミュニティの
慣習通り、`let` で `when` などの core 名を bind しないことが推奨されます。

**(4) `resolveMaybe`** は **失敗を null で返す** バリアントです。本来の
`analyzeSymbol` は失敗を `name_error` にして返しますが、ここでは
「macro じゃなかった」という情報を欲しいだけなので silent miss させ
ます。miss の error 報告は (5) の `analyzeCall` 内 `analyze(items[0],
...)` が担当します。

**(4) 再 analyse loop**。展開結果は `analyze(arena, rt, env, scope,
expanded, macro_table)` で再帰されます。`(cond p1 e1 p2 e2)` のように
展開後にも macro が残るパターンも、自然に止まるまで loop が回ります。

---

## 4. 9 個の Zig 変換の構造

`lang/macro_transforms.zig` は 9 個の Form → Form 変換を実装します。
それぞれ Zig 関数 1 つで、`registerInto(env, table)` で table に
登録 + `^:macro` Var を `rt` ns に intern します。内訳は次の三系統です。

### 4.1 単純な構造変換（4 つ）

```zig
// (let bindings body...) → (let* bindings body...)
// （現状は head rename のみ。destructuring は将来 phase）
fn expandLet(arena, rt, args, loc) -> Form {
    // [let* | bindings | body...] のリストを arena に組み立てる
}

// (when c body...) → (if c (do body...) nil)
fn expandWhen(arena, rt, args, loc) -> Form {
    // 1 body 形なら (do ...) を省略してそのまま埋める
}

// (cond p1 e1 p2 e2 ...) → 右結合の (if p1 e1 (if p2 e2 ...))
fn expandCond(arena, rt, args, loc) -> Form {
    // 偶数個チェック、再帰で tail を組み立てる
}
```

### 4.2 thread-first / thread-last（2 つ）

```zig
// (-> x (f a) (g b)) → (g (f x a) b)
// (->> x (f a) (g b)) → (g b (f a x))
fn threadStep(arena, acc, step, dir) -> Form {
    // step が bare symbol: (-> x f) → (f x)
    // step が list (f a b ...):
    //   first: (f a b ...) → (f acc a b ...)
    //   last : (f a b ...) → (f a b ... acc)
}
```

### 4.3 hygiene が要る短絡評価（4 つ）

`and / or / if-let / when-let` は **同じ部分式を 2 回評価しない** ため
gensym が要ります。

```zig
// (and x y...) → (let* [g x] (if g (and y...) g))
// (or  x y...) → (let* [g x] (if g g (or y...)))
fn buildShortCircuit(arena, gname, expr, then_branch, else_branch, loc, _: ShortCircuit) -> Form {
    // (let* [gname expr] (if gname <then_branch> <else_branch>))
}
```

`gname` は `Runtime.gensym(arena, "and")` で生成します。フォーマットは
Clojure 互換の `and__N__auto__` です。

```zig
pub fn gensym(self: *Runtime, arena, prefix) ![]const u8 {
    const n = self.gensym_counter;
    self.gensym_counter += 1;
    return std.fmt.allocPrint(arena, "{s}__{d}__auto__", .{prefix, n});
}
```

`(and 1 2 3)` を実際に手で展開すると、再展開 loop が gensym を含む
入れ子構造を順次組み立てる様子が観察できます。

1. `(and 1 2 3)` → `(let* [g 1] (if g (and 2 3) g))`
2. `(and 2 3)`   → `(let* [g2 2] (if g2 (and 3) g2))`
3. `(and 3)`     → `3`（単項 `and` は引数そのもの）

eval flow は次の通りです。

- 最外 `let*`: `g = 1` で bind、`(if g ...)` を評価。`g = 1` は truthy。
- 中間 `let*`: `g2 = 2` で bind、`(if g2 ...)` を評価。`g2 = 2` は truthy。
- 最内: `3`（リテラル）。

結果: `3` — **最後の truthy 値** を返すという `and` の Clojure semantic
を満たします。途中で falsy が出たら短絡し、その値を返します
（`(and 1 false 3)` → `false`）。

---

## 5. Form↔Value 境界の局所化

ADR 0001 の最大の副産物は、Form↔Value 変換が **1 箇所だけ** に集まる
ことでした。

| 経路                                     | Form/Value のどっちで動く                                   | 変換場所                                     |
|------------------------------------------|-------------------------------------------------------------|----------------------------------------------|
| Zig 変換（`let`, `when`, ...）           | Form のみ                                                   | 変換不要                                     |
| user `defmacro`（Phase 3.12）            | Form → Value で fn 起動 → Value → Form                   | `expandIfMacro` の user-fn fallback 内部のみ |
| `(quote x)`                              | Form → Value（lift）                                       | `analyzer::formToValue`                      |
| `(macroexpand-1 x)` primitive (Phase 5+) | Value で受けて Form に変換 → expandIfMacro → 結果を Value | primitive の中だけ                           |

重要なのは「Phase 3.7 の時点で 0 箇所、Phase 3.12 で 1 箇所、それ以降
拡張しても 1〜2 箇所」という増え方です。Form と Value をしっかり分離した
分、bridge 場所は限定されます。これは Clojure JVM の「すべてが Object」
モデルでは達成できない設計の純度です。

---

## 6. 設計判断と却下した代替

| 案                                                     | 採否 | 理由                                   |
|--------------------------------------------------------|------|----------------------------------------|
| A: analyzer から lang を import                        | ✗   | zone_deps 違反                         |
| B: vtable.expandMacro を維持して lang から install     | ✗   | Form↔Value 強制、Layer 0 責務逸脱     |
| C: TreeWalk が macro 経路を所有                        | ✗   | P12 dual-backend 違反                  |
| D: 独立 macroexpand pass                               | ✗   | lexical shadowing 解けない             |
| E: `pub var` registry                                  | ✗   | zone_deps Guard 3 違反                 |
| **F (採用): MacroTable を analyze の引数で threading** | ✓   | 全制約クリア、user defmacro へ拡張容易 |

ROADMAP § 2 / 原則 P3「core 安定」、P6「error quality 必須」、P12
「dual backend」、§4.1「zone」、§13「reject patterns」をすべて満たします。

---

## 7. 確認 (Try it)

```sh
git checkout 6630cbe
zig build

# Phase 3.7 exit criteria
./zig-out/bin/cljw - <<'EOF'
(let [x 1] (+ x 2))
EOF
# → 3

./zig-out/bin/cljw - <<'EOF'
(when true 42)
EOF
# → 42

./zig-out/bin/cljw - <<'EOF'
(when false 42)
EOF
# → nil

./zig-out/bin/cljw - <<'EOF'
(-> 1 (+ 2) (* 3))
EOF
# → 9

# 9 マクロ全部の e2e
bash test/e2e/phase3_cli.sh
# → 21/21 green (cases 12–19 が新規 macro テスト)
```

---

## 8. 教科書との対比

| 軸            | v1 (`~/Documents/MyProducts/ClojureWasm`) | v1_ref   | Clojure JVM                    | Babashka/SCI                 | 本リポジトリ                                                         |
|---------------|-------------------------------------------|----------|--------------------------------|------------------------------|----------------------------------------------------------------------|
| dispatch 場所 | `analyzeList()` inline                    | 未実装   | `Compiler.analyzeSeq()` inline | `sci.impl.analyzer` inline   | **Layer-1 `eval/macro_dispatch.Table` (extracted)**                  |
| transform 数  | 57 個（Zig）                              | 0        | core.clj (`defmacro`)          | core fns (SCI)               | 9 個（bootstrap のみ）                                               |
| Form vs Value | Form のみ                                 | 未実装   | Object（≒ Value）             | Object                       | **Form のみ（user defmacro 境界のみ Value 経由）**                   |
| backend 結合  | なし                                      | 該当なし | なし                           | 該当なし（interpreter only） | **明示的になし（vtable から削除済み）**                              |
| 状態管理      | comptime `StaticStringMap`                | 未実装   | runtime `Var meta`             | SCI evaluator state          | **runtime `StringHashMap`（Phase 3.12 で user macro を入れるため）** |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は dispatch を `analyzeList` に inline していました（57 個もあれ
  ば直書きのほうが速いという判断）。本リポジトリは extract して
  **テスト可能 / 再構成可能** な形にしています。9 個に絞ったのは
  bootstrap の最小集合だけに留めるためで、残りは Phase 3.12 の
  `core.clj` 上の `defmacro` で書きます。A2「新ファイル」と P3
  「core 安定」を満たす分割になっています。
- Clojure JVM の Object-level は homoiconic なので自然ですが、CW v2
  は Form / Value 分離を意図的に維持しています。Form-level macro は
  location が完全に保存され、P6 を満たします。
- Babashka / SCI には host 側の fast path がありません。CW v2 で Zig
  変換を持つのは v1 と同じ思想です。bootstrap macros を毎回 Clojure
  評価器で expand すると startup が遅くなるため、Zig 変換でゼロ
  コスト化しています。

---

## この章で学んだこと

- マクロ展開は backend 非依存の Form → Form 変換だから、vtable から
  外して Layer 1 の dispatcher に置くのが正しい場所。
- zone_deps 違反 / `pub var` 禁止 / lexical shadowing の三制約を同時に
  満たすのは MacroTable を analyze の引数で threading する DI 1 案だけ。
- Form↔Value 境界を user `defmacro` 1 箇所に閉じ込めたことで、
  Form-level の純粋な書き換えとして 9 マクロが扱える。

---

## 次へ

第 20 章: [Phase 3 後半 — print 抽出 + try/catch/throw](./0020_phase3_completion.md)
