---
commits:
  - 91feef0
  - 07d5c34
  - e20acaa
  - e04c290
  - bb1459c
  - de2cb64
  - f81f97a
  - 8d0c677
  - 04e84bf
  - 8d32c83
  - 7d9fe5f
date: 2026-04-26
scope:
  - src/runtime/dispatch.zig
  - src/runtime/runtime.zig
  - src/runtime/env.zig
  - src/runtime/keyword.zig
  - src/eval/node.zig
  - src/eval/analyzer.zig
  - src/eval/backend/tree_walk.zig
  - src/lang/primitive.zig
  - src/lang/primitive/math.zig
  - src/lang/primitive/core.zig
  - src/main.zig
  - test/e2e/phase2_exit.sh
related:
  - ROADMAP §4.3 (Runtime + std.Io DI)
  - ROADMAP §4.4 (dual backend)
  - ROADMAP §9.4 (Phase-2 task list 2.1–2.11)
  - 原則 P9 (one task = one commit) / P10 (Zig 0.16 idioms)
---

# 0008 — Phase 2: Runtime / Analyzer / TreeWalk と Read–Analyse–Eval–Print

## 背景 (Background)

Phase 2 の到達点は **「`cljw -e "(let* [x 1] (+ x 2))"` が `3` を返す」**。
Phase 1 の Read–Print 往復に **解析 (Analyzer)** と **評価 (TreeWalk)**
を挟み、ROADMAP §4 の三層 (Runtime / Env / threadlocal) に乗った
評価器をボトムアップで組む。

ここで押さえる処理系理論：

- **Tagged union による analyzed AST**: Reader が出す `Form` (surface
  syntax) と、Analyzer が出す `Node` (resolved AST) を分けるのは
  処理系の常套手段。Symbol は `LocalRef` (slot index) か `VarRef`
  (Var pointer) に解決された後の Node にする。これで backend は
  HashMap を一切叩かず、配列インデックスで局所変数を読める。
- **Slot allocation at analyse time**: `let*` / `fn*` で出会う名前に
  分析時点で `u16` slot を割り当て、子スコープは `next_slot` を
  親から継承する。関数全体が 1 つのフラットな locals 配列を共有
  するため、TreeWalk は固定サイズ `[256]Value` で済む。
- **Recursive descent interpreter**: `eval(node)` は `switch (node.*)`
  で各 variant を直接処理する素朴な再帰下降。性能を出すのは
  Phase 4 の bytecode VM の役目で、Phase 2 のここは「正解の振る舞い」
  を定義するためのリファレンスとして十分。
- **vtable injection (Layer 0 ← Layer 1)**: `Runtime.vtable: ?VTable`
  を Layer 0 で型だけ宣言し、起動時に Layer 1 (TreeWalk) が
  `installVTable(rt)` で関数ポインタを書き込む。これで「下位 zone は
  上位 zone を import しない」を保ったまま、論理的な呼び出し方向
  (eval → call backend) を実現できる。
- **Dynamic binding via threadlocal frame chain**: `^:dynamic` Var の
  `deref` は threadlocal `current_frame` を上から走査して最初に
  見つかった束縛を返す。`(binding [...] body)` は `pushFrame` /
  `popFrame` の対で実装される。Clojure の dynamic-var セマンティクスは
  thread-local が言語仕様なので、ここだけは threadlocal が load-bearing。
- **Lookup priority (Clojure)**: 名前解決は **locals → 自 ns mappings →
  自 ns refers** の順。Phase 2 では `(refer 'rt)` 相当 (`Env.referAll`)
  で primitives を `user/` の refers に流し込み、未修飾の `+` が
  解決できるようにしている。

Zig 0.16 のイディオム：

- `enum(u64)` の Value に `.fn_val` 等の sub-tag を sub-bit 領域に
  載せ、`encodeHeapPtr` で u64 化。`Function` 構造体は `extern
  struct { header: HeapHeader, _pad: [6]u8, ... }` のレイアウトで
  8 バイトアラインを保つ。
- 循環 import: `dispatch.zig` の `*Runtime` 参照と `runtime.zig` の
  `?VTable` 参照は循環するが、Zig は型解決が遅延するので
  ポインタ型なら問題なく compile する。3 ファイル (dispatch /
  runtime / env) を 1 commit で投入する設計上の制約は、これに起因。
- `std.Io.Mutex.lockUncancelable(rt.io)`: Phase 2 はシングルスレッドだが、
  rt-aware API の段階で mutex を埋め込んでおくと Phase 15 の
  並行化が touch なし。コストはほぼ load + store の 2 命令分。
- `inline else => |n| n.loc`: tagged union の variant 全てに同じ
  field がある場合、`inline else` で 1 行に畳める。
- `std.StaticStringMap(...)`: special form のディスパッチを
  comptime hash table 化。analyze 経路の 1 ヶ所だけのために
  実行時 HashMap を作るのは無駄。

Clojure 仕様の関連箇所：

- `let` は macro、本体は `let*`。Phase 2 は macro expansion を
  まだ持たない (Phase 3+) ので、exit criterion のテストでも
  `let*` を使う。`(let [x 1] ...)` 表記を受け付けるのは Phase 3。
- `(- )` は Clojure では ArityException; `(+ )` は 0、`(* )` は 1。
  identity element の慣習を vs Phase 2 minimum でも踏襲。
- `(true? 1)` は **false**: Clojure の truthiness と `true?` の
  strict な true 判定は区別される。truthiness 判定は `if` の中。
- `(false? nil)` も **false**: nil と false は別の singleton。

## やったこと (What)

11 source commits (うち 1 件は test/e2e の追加)。**Phase 2.1 だけは
3 ファイル同時投入**で、残りは 1 task = 1 commit。

### 91feef0 — feat(runtime): land dispatch + Runtime + Env skeletons together

- 新規: `runtime/dispatch.zig`, `runtime/runtime.zig`, `runtime/env.zig`

`dispatch.VTable` が `*Runtime` / `*Env` を参照する循環 import の
都合上、3 ファイルを 1 commit で着地。`Env` はこの段階では
コンパイル可能な最小形 (`rt` + `alloc` field のみ)。

### 07d5c34 — refactor(runtime): promote KeywordInterner to rt-aware

- 編集: `runtime/keyword.zig`

Phase 1 の `interner.intern(self, ns, name)` を `internUnlocked` に
リネームし、新 top-level `intern(rt, ns, name)` が
`rt.keywords.mutex.lockUncancelable(rt.io)` でロックを取る。
セルレイアウトは凍結のまま。

### e20acaa — feat(runtime): flesh out Env

- 編集: `runtime/env.zig` (skeleton → full)

`Var` (root + `VarFlags`)、`Namespace` (mappings + refers + aliases)、
threadlocal `current_frame` + `BindingFrame` chain、`pushFrame` /
`popFrame` / `findBinding`、`Env.findOrCreateNs` / `findNs` /
`referAll` / `intern`。`Env.init(rt)` で `rt` と `user` の 2 つを
事前作成し、`current_ns = user`。

### e04c290 — feat(eval): add analysed AST Node tagged union

- 新規: `eval/node.zig`

`Node = union(enum)` の 10 variants (constant / local_ref / var_ref /
def_node / if_node / do_node / quote_node / fn_node / let_node /
call_node)。各 variant は `loc: SourceLocation` を持ち、`Node.loc()`
は `inline else => |n| n.loc`。

### bb1459c — feat(eval): add Phase-2 Analyzer

- 新規: `eval/analyzer.zig`

`Form → Node`。6 special forms (def / if / do / quote / fn* / let*)
を `std.StaticStringMap` でディスパッチ。`Scope` chain で局所変数の
slot を分析時点で割り当て、`let*` / `fn*` の body は単一 form なら
そのまま、複数なら `do_node` に畳む。`(quote x)` は atom のみ
リフト、symbol/list は Phase 3+ の `NotImplemented`。

### de2cb64 — feat(eval): add Phase-2 TreeWalk backend

- 新規: `eval/backend/tree_walk.zig`

`Function` heap struct + `allocFunction` (rt.trackHeap 経由で寿命管理)。
`eval(rt, env, locals, node)` driver、`treeWalkCall(rt, env, callee,
args)` dispatcher (fn_val / builtin_fn を switch)、`installVTable(rt)`。
locals は固定 256 slot 配列。closure capture は Phase 2 では未対応
(top-level fn と global Var 参照のみ動く)。

ここで Phase-2 exit criterion の **両方** (test 内の inline 版 `+`
で) パスを確認: `(let* [x 1] (+ x 2))` → 3 / `((fn* [x] (+ x 1)) 41)`
→ 42。

### f81f97a — feat(lang): add math primitives

- 新規: `lang/primitive/math.zig`

`+`, `-`, `*`, `=`, `<`, `>`, `<=`, `>=`, `compare`。Float-contagion
(混合は f64 に拡幅)、integer overflow → float promotion (`Value
.initInteger` の責務)。`pairwise` で `<` / `>` / `<=` / `>=` / `=`
を 1 ループに畳む。

### 8d0c677 — feat(lang): add core predicate primitives

- 新規: `lang/primitive/core.zig`

`nil?`, `true?`, `false?`, `identical?` の 4 述語。NaN-boxed Value
の bit 比較のみで判定するので、allocation も vtable detour もなし。

### 04e84bf — feat(lang): add registerAll entry point

- 新規: `lang/primitive.zig`

`registerAll(env)` が math + core を `rt/` に登録し、`Env.referAll(rt,
user)` で `user/` の refers に流す。idempotent (再実行で重複しない)。
Phase 3+ は `try X.register(env, rt_ns)` 行を足すだけで拡張可能。

### 8d32c83 — feat(app): wire cljw CLI through analyser + TreeWalk

- 編集: `src/main.zig`

`-e <expr>` の経路を Read–Print から Read–Analyse–Eval–Print に
昇格。boot 順は `Runtime.init → Env.init → installVTable →
registerAll`。`printValue` を main.zig 内に配置 (Phase 3+ で
`runtime/print.zig` に切り出す予定)。

### 7d9fe5f — test(e2e): pin Phase-2 CLI exit criteria

- 新規: `test/e2e/phase2_exit.sh`、編集: `test/run_all.sh`

`cljw -e ...` の stdout 内容と exit code を 3 ケース固定し、
`run_all.sh` の suite #3 として配線。これで Phase 2 の振る舞いが
将来 regress した時に即座に光る。

## コード (Snapshot)

### 三層アーキテクチャの境界 (Layer 0 / 1 / 3)

```zig
// runtime/dispatch.zig — Layer 0 が宣言する型
pub const CallFn = *const fn (
    rt: *Runtime, env: *Env, fn_val: Value, args: []const Value,
) anyerror!Value;

pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
    expandMacro: ExpandMacroFn,
};

// eval/backend/tree_walk.zig — Layer 1 が起動時に注入
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &treeWalkCall,
        .valueTypeKey = &valueTypeKey,
        .expandMacro = &expandMacroStub,
    };
}
```

### Analyzer の Scope chain

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

### TreeWalk の eval driver

```zig
pub fn eval(rt: *Runtime, env: *Env, locals: []Value, node: *const Node) anyerror!Value {
    return switch (node.*) {
        .constant => |n| n.value,
        .local_ref => |n| if (n.index >= locals.len) error.SlotOutOfRange else locals[n.index],
        .var_ref => |n| n.var_ptr.deref(),
        .if_node => |n| try evalIf(rt, env, locals, n),
        .let_node => |n| try evalLet(rt, env, locals, n),
        .fn_node => |n| try allocFunction(rt, n),
        .call_node => |n| try evalCall(rt, env, locals, n),
        // ...
    };
}
```

### CLI の RAEP ループ

```zig
var rt = Runtime.init(io, gpa);
defer rt.deinit();
var env = try Env.init(&rt);
defer env.deinit();
tree_walk.installVTable(&rt);
try primitive.registerAll(&env);

var reader = Reader.init(arena, expr.?);
while (true) {
    const form = try reader.read() orelse break;
    const node = try analyzeForm(arena, &rt, &env, null, form);
    var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
    const result = try tree_walk.eval(&rt, &env, &locals, node);
    try printValue(stdout, result);
    try stdout.writeByte('\n');
}
```

## なぜ (Why)

**設計判断と却下した代替**

- 代替 A: `Form` をそのまま eval する (analyse step を省く)。
  却下: backend が毎回 symbol を resolve することになり、
  HashMap lookup が hot path に乗る。slot index を analyse 時に
  確定させると、TreeWalk も VM も配列アクセスだけで済む。

- 代替 B: `pub var callFn = undefined;` (v1 のスタイル)。
  却下: テストで mock を注入できない、複数 Runtime が
  別々の backend を持てない。`Runtime.vtable: ?VTable` field 化で
  両方が解決する。

- 代替 C: `loop*` / `recur` も Phase 2 で入れる。
  却下: exit criterion に不要、かつ recur は threadlocal pending_recur
  で ergonomic な実装になるので Phase 3 の制御フロー回 (try/throw)
  と一緒に入れた方が一貫性がある。

- 代替 D: lexical closure を Phase 2 で実装する。
  却下: `(let [x 1] (fn [y] (+ x y)))` のような環境捕捉は capture
  vector が要る。Phase 2 の exit criterion (`((fn* [x] x) 41)`) は
  capture 不要なので、複雑性は Phase 3 に送る。

- 代替 E: `printValue` を `runtime/value.zig` の method に置く。
  却下: heap 種別の print (Function / list / keyword) をすべて
  value.zig に集めると Layer 0 が Layer 1 の知識を持つことになる。
  Phase 3 で `runtime/print.zig` を独立させる。

**ROADMAP / 原則への対応**

- §4.3 (Runtime + std.Io DI) — 完全準拠。`Runtime` は io / gpa /
  keywords / vtable / heap_objects を持つ。
- §4.4 (dual backend) — TreeWalk が installVTable で VTable を
  注入する形を確立。Phase 4 の VM が同じ slot で installVTable
  すれば dual backend が成立する。
- 原則 P9 — Phase 2 の 11 タスクを 11 commit に分解 (2.1 だけは
  循環 import の都合で 3 ファイル / 1 commit)。
- 原則 P10 — `std.Io.Mutex` / `enum(u64)` / `extern struct` /
  `packed struct(<width>)` / `inline else` / `StaticStringMap` の
  Zig 0.16 イディオムを採用。

## 確認 (Try it)

```sh
git checkout 7d9fe5f
zig build
./zig-out/bin/cljw -e "(+ 1 2)"                   # → 3
./zig-out/bin/cljw -e "(let* [x 1] (+ x 2))"      # → 3   (exit 1/2)
./zig-out/bin/cljw -e "((fn* [x] (+ x 1)) 41)"    # → 42  (exit 2/2)
./zig-out/bin/cljw -e "(if (< 1 2 3) :asc :no)"   # → :asc
./zig-out/bin/cljw -e "(nil? nil)"                # → true
./zig-out/bin/cljw -e "(identical? :foo :foo)"    # → true (interned)

bash test/run_all.sh   # 176 unit + zone gate + e2e all green
```

## 学び (Takeaway)

**処理系一般**

- Form と Node を分ける段階分割は一見遠回りだが、symbol 解決と
  slot 割当てが analyse に押し出されると backend の hot path が
  劇的に単純になる。VM が分担する 32 種くらいの opcode のうち、
  `LOAD_LOCAL slot` の slot は **analyzer が決めた値**になる。
- 循環 import を恐れない: 型解決が遅延する言語 (Zig / TypeScript /
  OCaml の module rec) では、双方向参照の structure は素直に書ける。
  分けたい時は分けて、分けられない時は 1 commit で揃える。
- `installVTable` パターンは「下位レイヤが上位レイヤを呼ぶ」を
  実現する常套手段。dispatch.callFn が null check 1 つで通れば、
  あとは function pointer indirect call。

**Zig 0.16**

- `Runtime.vtable: ?VTable` を `pub var` でなく field にすると、
  test fixture で mock を差し込めるしマルチテナントも可能。
  「グローバルの誘惑」を抱き止める良い習慣。
- `inline else => |n| n.loc` で tagged union の field 共通アクセスは
  1 行。switch を 10 個並べる必要はない。
- `std.Io.Mutex.lockUncancelable(io)` の `io` 引数を取り回すために
  Runtime が io を保持するのは payoff が大きい。後付けは厳しい。

**Clojure**

- `let*` と `let` の関係 (special form と macro) は最初に意識して
  おくとよい。Phase 2 で `let*` を直接書かせるのは macroexpansion
  の責務分離を可視化するため。
- name resolution の優先順 (locals → mappings → refers) を
  Namespace.resolve に閉じ込めると、analyzer は「Var が見えるか」
  だけ気にすればいい。

**プロジェクト運用**

- 11 task のうち 9 task は v1_ref からの adapt + テスト書き直しで
  済んだ。Phase 1 が "layout 凍結" 重視だったのに対し、Phase 2 は
  "実装の具体" が増えるので、TDD の「red → green」が機能する場面が
  多い (特に analyzer の slot 割当て、tree_walk の closure 取扱い、
  primitive の identity element 規約)。
- e2e gate (`test/e2e/phase2_exit.sh`) を unit test に並べて
  `run_all.sh` から呼ぶことで、CLI を含む end-to-end 振る舞いの
  regression を即座に検出できる。Phase 3 以降も同じパターンで
  追加していく。
