---
chapter: 14
commits:
  - de2cb64
related-tasks:
  - §9.4 / 2.6
related-chapters:
  - 0013
  - 0015
date: 2026-04-27
---

# 0014 — TreeWalk: Node を Value に評価する

> 対応 task: §9.4 / 2.6 / 所要時間: 90〜120 分

Analyzer が Node tree に変換し終わった式を、再帰下降で **Value に
落とす** Phase-2 backend。Clojure ランタイムが **初めて式を実行する
瞬間** を扱う章。10 種類の Node variant を switch dispatch、
`Function` を heap allocate、48-bit ポインタ表現の `builtin_fn` を
呼ぶ、そして `installVTable` で Layer-0 → Layer-1+ の依存反転を
完成させる。

Phase 4 で bytecode VM が来てもこの TreeWalk は **消さず残し続ける**:
**dual-backend 検証** (ROADMAP §4.4) の参照実装として、VM の出力を
TreeWalk と比較する。

---

## この章で学ぶこと

- `eval(rt, env, locals, node) → anyerror!Value` の **4 引数の意味**、
  なぜ戻り値が `anyerror!Value` か (vtable の error union 規則)
- 10 Node variant ごとの **switch dispatch** と Phase-2 で何が動くか
- `Function` heap struct の **8-byte alignment 確保** と `_pad: [6]u8`
- `allocFunction(rt, fn_node)` と `rt.trackHeap` による Phase-5 GC
  までの寿命管理
- **48-bit fn pointer による Builtin 表現**: heap object なしで Value
  に直接 encode、`asBuiltinFn(FnPtr)` で型指定 decode
- `installVTable(rt)` のタイミング: `Runtime.init` 直後に呼んで
  Layer-0 dispatch を Layer-1 backend で埋める
- Phase 2 の境界: closure capture 無し、`recur` は Phase 3+ だが
  eval signature は最初からそれに耐える形 (`anyerror!Value`)

---

## 1. シグネチャと dispatch の全体像

```zig
pub fn eval(rt: *Runtime, env: *Env, locals: []Value, node: *const Node) anyerror!Value {
    return switch (node.*) {
        .constant   => |n| n.value,
        .local_ref  => |n| { /* locals[n.index] */ },
        .var_ref    => |n| n.var_ptr.deref(),
        .def_node   => |n| try evalDef(rt, env, locals, n),
        .if_node    => |n| try evalIf(rt, env, locals, n),
        .do_node    => |n| try evalDo(rt, env, locals, n.forms),
        .quote_node => |n| n.quoted,
        .fn_node    => |n| try allocFunction(rt, n),
        .let_node   => |n| try evalLet(rt, env, locals, n),
        .call_node  => |n| try evalCall(rt, env, locals, n),
    };
}
```

| 引数     | 役割                                                            |
|----------|-----------------------------------------------------------------|
| `rt`     | Function alloc + vtable.callFn を引く                           |
| `env`    | def/var_ref で namespace を引く、call で env を渡す             |
| `locals` | 256-slot 配列 (caller の stack array)、`local_ref` の slot 用    |
| `node`   | analyse 済 Node の借用ポインタ                                   |

### `anyerror!Value` という戻り値型

戻り値が `anyerror!Value` で `EvalError!Value` ではないのは、**vtable
経由の error union 規則** のため。`runtime/dispatch.zig` の
`CallFn = *const fn(...) anyerror!Value` を呼んだ瞬間 `evalCall` の
error set が anyerror に広がる。Zig の error union は **狭めるのは
OK、広げるとエラー** なので、これを呼ぶ `eval` 全体を `anyerror!Value`
にしておく必要がある。

第 2 の理由は **Phase 3 で来る `recur` のため** (§9 で詳述)。recur は
`error.RecurSignaled` を投げる threadlocal pattern で実装予定で、eval
signature を `anyerror!Value` にしておけば error set 追加だけで済む。

### 演習 14.1: error union widen を観察 (L1)

`eval` 全体を `!Value` (inferred error set) にして `evalCall` 経路で
再帰させると何が起きる？

<details>
<summary>答え</summary>

`error: function with inferred error set called recursively / cannot
resolve inferred error set` でコンパイル失敗。Zig は再帰関数 +
inferred error set を解決できず、**明示的に `anyerror` を書く必要が
ある** — これが本リポで `eval` を `anyerror!Value` にしている
コンパイルレベルの強制力。

</details>

---

## 2. Constant / LocalRef / VarRef — 自明な 3 つ

```zig
.constant   => |n| n.value,
.local_ref  => |n| {
    if (n.index >= locals.len) return EvalError.SlotOutOfRange;
    return locals[n.index];
},
.var_ref    => |n| n.var_ptr.deref(),
```

ホットパスは **配列 index と pointer load** のみ。HashMap も string
compare も無い。これが第 12 章「解析を前倒しする価値」の正味。
`var_ptr.deref()` は Phase 3 で dynamic binding stack を実装したら
override も拾うようになる (Phase 2 では root を返すだけ)。

---

## 3. `evalIf` / `evalDo` / `evalDef` / `evalLet`

- `evalIf`: `cond.isTruthy()` で分岐 (「nil でも false でもない」が真)、
  else 不在なら `nil_val` 返却
- `evalDo`: forms 順次 eval、最後の値返却 (空 do は `nil_val` 初期値)
- `evalDef`: value eval → `Env.intern` → flag 立て → `.var_ref` Value
  返却 (v1 と同じく `(def x 1)` の戻り値は Var そのもの)
- `evalLet`: caller-provided な locals 配列に書き込むだけ。新しい
  配列を作らない (analyzer の `next_slot` 継承で nested let* の slot
  が被らないので OK)

```zig
fn evalLet(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.LetNode) !Value {
    for (n.bindings) |b| {
        if (b.index >= locals.len) return EvalError.SlotOutOfRange;
        locals[b.index] = try eval(rt, env, locals, b.value_expr);
    }
    return eval(rt, env, locals, n.body);
}

fn evalDef(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.DefNode) !Value {
    const v = try eval(rt, env, locals, n.value_expr);
    const ns = env.current_ns orelse return EvalError.NotImplemented;
    const var_ptr = try env.intern(ns, n.name, v);
    var_ptr.flags.dynamic = n.is_dynamic;
    var_ptr.flags.macro_ = n.is_macro;
    var_ptr.flags.private = n.is_private;
    return Value.encodeHeapPtr(.var_ref, var_ptr);
}
```

### 演習 14.2: `evalLet` の locals 遷移 (L1)

`(let* [x 1 y 2] x)` を eval すると、各 step で `locals` の状態は？

<details>
<summary>答え</summary>

```
step 0:  [nil, nil, nil, ...]    ← 256 個 nil 初期化
step 1:  [1, nil, nil, ...]      ← x bind
step 2:  [1, 2, nil, ...]        ← y bind
step 3:  eval body x → locals[0] = 1 → return 1
```

slot 2 以降は触らない。call が終わると locals 配列ごと破棄 (stack)。

</details>

---

## 4. `Function` heap struct と 8-byte alignment

```zig
pub const Function = struct {
    header: HeapHeader,
    _pad: [6]u8 = undefined,
    arity: u16,
    has_rest: bool,
    body: *const Node,
    params: []const []const u8,
};
```

### `_pad: [6]u8` の正体

第 0002 章で見た **NaN boxing の 8-byte alignment 制約** に対応する
ため。`encodeHeapPtr` は `&function` のアドレスが 8 で割り切れることを
要求する。`HeapHeader` は 2 bytes、その後 6 bytes の padding を挟む
ことで `Function` 全体の `@alignOf` が 8 になる。テスト:

```zig
test "Function is 8-byte aligned (NaN boxing safety)" {
    try testing.expectEqual(@as(usize, 8), @alignOf(Function));
}
```

### `allocFunction` — heap allocate + trackHeap

```zig
pub fn allocFunction(rt: *Runtime, fn_node: node_mod.FnNode) !Value {
    const f = try rt.gpa.create(Function);
    f.* = .{
        .header = HeapHeader.init(.fn_val),
        .arity = fn_node.arity, .has_rest = fn_node.has_rest,
        .body = fn_node.body, .params = fn_node.params,
    };
    try rt.trackHeap(.{ .ptr = @ptrCast(f), .free = freeFunction });
    return Value.encodeHeapPtr(.fn_val, f);
}
```

3 step: `gpa.create` → `trackHeap` 登録 → `encodeHeapPtr(.fn_val, f)`。
`trackHeap` が要るのは **Phase 5 GC が来るまでの寿命管理**: それまで
は `Runtime.deinit` が trackHeap 登録された全 heap object を free。
Phase 5 で GC が走り出したら Function も普通の heap object として
trace 対象になる。

### Phase 2 の Function は **closure capture を持たない**

`Function` 構造体に `captured: []Value` フィールドが無い。

```clojure
(let* [x 1] (fn* [y] (+ x y)))   ; ← Phase 2 では動かない
```

body の `x` は `LocalRef{ slot: 0 }` を指すが、生成された Function
が呼ばれる時点では **新しい locals 配列** が用意されていて外側の
`x` がいない。Phase 3+ で `Function.captured: []Value` を追加し、
analyse 時点で free variable を集めて allocFunction 時に固める予定。

### 演習 14.3: `_pad` を消したら (L2)

`_pad: [6]u8` を消した `Function` で `encodeHeapPtr` を呼ぶと？

<details>
<summary>答え</summary>

`Function` の自然 alignment は内部最大 (`*const Node` = 8 bytes) で
決まるので **結果として 8 byte alignment は保たれる** ことが多い。
だが Zig の field reorder/padding に依存。`_pad` 明示は **将来 field
入れ替えても alignment が壊れない保険** で、`@alignOf(Function) == 8`
が変わったら debug build で alignment テストが落ちる ⇒ release で
`assert(addr & 0x7 == 0)` が hit する前に検出できる。

</details>

---

## 5. `evalCall` と `treeWalkCall` — 呼び出しの 2 段ディスパッチ

```zig
fn evalCall(rt: *Runtime, env: *Env, locals: []Value, n: node_mod.CallNode) !Value {
    const callee = try eval(rt, env, locals, n.callee);
    var args_buf: [MAX_LOCALS]Value = undefined;
    for (n.args, 0..) |*a, i| { args_buf[i] = try eval(rt, env, locals, a); }
    if (rt.vtable) |vt| {
        return vt.callFn(rt, env, callee, args_buf[0..n.args.len]);
    }
    return EvalError.NotCallable;
}

pub fn treeWalkCall(rt: *Runtime, env: *Env, callee: Value, args: []const Value) anyerror!Value {
    return switch (callee.tag()) {
        .fn_val     => callFunction(rt, env, callee, args),
        .builtin_fn => callBuiltin(rt, env, callee, args),
        else        => EvalError.NotCallable,
    };
}
```

`evalCall` は callee と args を eval して **`rt.vtable.callFn` 経由で
dispatch**。これが `installVTable` で `treeWalkCall` 自身に解決される
ので結局自身を間接呼出。なぜ vtable 経由か：**Phase 4 で VM が来たら
`vtable.callFn = vmCall` に差し替えるだけで eval 全体が VM に
切り替わる**。frontend は backend に依存しないというレイヤ規律を
vtable 一段で実現。

### `callFunction` — ユーザ定義関数

```zig
fn callFunction(rt: *Runtime, env: *Env, fn_val: Value, args: []const Value) !Value {
    const f = fn_val.decodePtr(*Function);
    if (!f.has_rest) {
        if (args.len != f.arity) return EvalError.ArityMismatch;
    } else {
        if (args.len < f.arity) return EvalError.ArityMismatch;
    }
    var locals: [MAX_LOCALS]Value = [_]Value{.nil_val} ** MAX_LOCALS;
    for (args[0..f.arity], 0..) |v, i| { locals[i] = v; }
    if (f.has_rest) locals[f.arity] = .nil_val;   // Phase-2 stub
    return eval(rt, env, &locals, f.body);
}
```

- `decodePtr(*Function)` で `*Function` 復元、arity チェック
- **新しい 256-slot 配列を stack に作る** (frame 独立、C の auto 変数
  と同じ)、args を `locals[0..arity]` にコピー
- has_rest は **Phase-2 stub**: rest を list 化する処理は Phase 5
  collection 待ちで `nil_val` 仮置き (Phase 2 では観測しない)

### 演習 14.4: ArityMismatch の場面 (L1)

どれが ArityMismatch を投げる？

```clojure
1. (def id (fn* [x] x))         (id)
2. (def id (fn* [x] x))         (id 1 2)
3. (def f (fn* [x & rest] x))   (f)
4. (def f (fn* [x & rest] x))   (f 1 2 3)
```

<details>
<summary>答え</summary>

| Case | 結果              | 理由                                                  |
|------|-------------------|-------------------------------------------------------|
| 1    | **ArityMismatch** | arity=1, args=0                                       |
| 2    | **ArityMismatch** | arity=1, args=2、has_rest=false で正確 1 必要         |
| 3    | **ArityMismatch** | has_rest でも min 1 必要                              |
| 4    | OK (returns 1)    | has_rest なので args ≥ 1 で OK                        |

</details>

---

## 6. 48-bit fn pointer による `Builtin` 表現

第 0002 章 §1 で見た `0xFFFF_xxxx_xxxx_xxxx` が **`builtin_fn` tag**。
heap object **無し** で fn pointer 自体を Value に詰める。

```zig
pub fn initBuiltinFn(fn_ptr: anytype) Value {
    const addr: u64 = @intFromPtr(fn_ptr);
    std.debug.assert(addr <= NB_PAYLOAD_MASK);     // 48-bit に収まる
    return @enumFromInt(NB_BUILTIN_FN_TAG | addr);
}

pub fn asBuiltinFn(self: Value, comptime FnPtr: type) FnPtr {
    const raw = @intFromEnum(self) & NB_PAYLOAD_MASK;
    return @ptrFromInt(raw);
}
```

x86_64/ARM64 の canonical address space は実用上 48 bit。heap
ポインタは 8-byte align で 45 bit に圧縮するが、**関数ポインタは
align できない** ので 48 bit そのまま使う (`builtin_fn` だけ別 tag
`0xFFFF`)。`comptime FnPtr` で型を呼び出し側に決めさせるのが key —
`value.zig` 自身は `dispatch.BuiltinFn` を import しなくて済む
(zone 違反回避)。呼び出し側 `callBuiltin`:

```zig
const fn_ptr = callee.asBuiltinFn(dispatch.BuiltinFn);
return fn_ptr(rt, env, args, .{});
```

### なぜ heap object に逃がさないか

| 軸                 | heap object 案 (v1 初期) | 48-bit fn pointer (本リポ) |
|--------------------|--------------------------|-----------------------------|
| builtin 起動       | 200+ alloc               | 0 alloc                     |
| identity 比較      | pointer 比較             | `==` 1 回                   |
| GC trace           | 対象 (永続なのに無意味) | 対象外                      |
| cold start         | 遅延                     | 影響なし                    |

ROADMAP の **「sub-10 ms cold start」** (原則 P10) に直接効く設計。

### 演習 14.5: encode/decode を書き起こす (L2)

ファイル名と公開 API のみ:
- `src/runtime/value.zig`、定数 `NB_BUILTIN_FN_TAG=0xFFFF_0000_0000_0000`,
  `NB_PAYLOAD_MASK=0x0000_FFFF_FFFF_FFFF`
- `pub fn initBuiltinFn(fn_ptr: anytype) Value`
- `pub fn asBuiltinFn(self: Value, comptime FnPtr: type) FnPtr`
- Roundtrip: `Value.initBuiltinFn(&f).asBuiltinFn(@TypeOf(&f))` が
  `&f` と一致

<details>
<summary>答え骨子</summary>

上の本文の `initBuiltinFn` / `asBuiltinFn` 実装がそのまま答え。
`comptime FnPtr` で型を呼び出し側に決めさせるのが key (zone 規律の
ため `value.zig` は dispatch を import しない)。

</details>

---

## 7. `installVTable` — Layer 反転を完成させる

```zig
pub fn installVTable(rt: *Runtime) void {
    rt.vtable = .{
        .callFn = &treeWalkCall,
        .valueTypeKey = &valueTypeKey,
        .expandMacro = &expandMacroStub,
    };
}
```

3 つの fn pointer を `Runtime.vtable` に書き込む。`Runtime.vtable:
?VTable` は `Runtime.init()` 直後は `null`、誰かが install するまで
`vt.callFn` は呼べない (`evalCall` が `if (rt.vtable) |vt|` で守る)。

### 呼ぶタイミング: `Runtime.init` 直後、`primitive.registerAll` の前

```zig
var rt = Runtime.init(io, gpa);          // vtable = null
var env = try Env.init(&rt);             // user namespace 作成
tree_walk.installVTable(&rt);            // ← ここで vtable 入る
try lang.primitive.registerAll(&env);    // builtins を namespace に intern
```

順序が重要なのは、`installVTable` 前に `evalCall` するとクラッシュ
する (vtable null) ため。`valueTypeKey` (multimethod 用、Phase 6+) と
`expandMacroStub` (Phase 3 で wires) も stub で入れておく — **vtable
の全フィールドを埋めないと struct literal が通らない** ため。

---

## 8. 演習 14.6: 9 variant の eval を予測 (L2)

`call_node` 以外の 9 variant について、何を返すか / 何を呼ぶかを
1 行で書く。

<details>
<summary>答え</summary>

| variant       | eval の動作                                          |
|---------------|------------------------------------------------------|
| `.constant`   | `n.value` 即値返却                                  |
| `.local_ref`  | `locals[n.index]`                                   |
| `.var_ref`    | `n.var_ptr.deref()`                                 |
| `.def_node`   | eval(value_expr) → intern → flag → `.var_ref` Value |
| `.if_node`    | cond truthy なら then、それ以外は else (or nil)     |
| `.do_node`    | forms 順次 eval、最後の値                           |
| `.quote_node` | `n.quoted` を即返却 (analyzer が reify 済)          |
| `.fn_node`    | `allocFunction(rt, n)` で fn_val                    |
| `.let_node`   | bindings を slot に書いて body を eval              |

`call_node` だけが「**vtable 経由で別関数を呼ぶ**」特殊扱い。これに
より Phase 4 の VM がここを差し替えるだけで全体が切り替わる。

</details>

---

## 9. 将来設計: `recur` の threadlocal pattern

Phase 2 にはまだ `loop*` / `recur` が無い。だが eval の戻り値型を
`anyerror!Value` にしたのは Phase 3+ でこの pattern が来るのを想定
しているから。Zig には本来の TCO がないので、recur は **threadlocal
で引数を stash + tagged error を投げる + loop の catch で受ける**
pattern で実装する (v1_ref で実証済):

```zig
threadlocal var pending_recur: ?[]Value = null;

fn evalRecur(rt: *Runtime, env: *Env, locals: []Value, n: RecurNode) !Value {
    const buf = try arena.alloc(Value, n.args.len);
    for (n.args, 0..) |*a, i| { buf[i] = try eval(rt, env, locals, a); }
    pending_recur = buf;
    return error.RecurSignaled;       // ← この error を loop が catch
}

fn evalLoop(rt: *Runtime, env: *Env, locals: []Value, n: LoopNode) !Value {
    for (n.bindings) |b| { locals[b.index] = try eval(...); }
    while (true) {
        const result = eval(rt, env, locals, n.body) catch |err| switch (err) {
            error.RecurSignaled => {
                const args = pending_recur orelse return EvalError.NotImplemented;
                pending_recur = null;
                for (n.bindings, 0..) |b, i| { locals[b.index] = args[i]; }
                continue;             // ← ジャンプ命令の代用
            },
            else => return err,
        };
        return result;
    }
}
```

threadlocal を使う理由: error union で値を運べない → 別 channel 必要。
同一スレッドで複数の `loop*` が並行することは無い (recur は **直近の
loop** にしか飛ばない) ので thread safety OK。Phase 2 の eval
signature を `anyerror!Value` にしておけば Phase 3 で
`EvalError.RecurSignaled` を error set に加えるだけで動く。

### 演習 14.7: `evalLoop` を再構成 (L3)

シグネチャと要求だけ与え、本体を書き起こす。要求: 初期 binding 評価
→ body 評価 → `error.RecurSignaled` を catch して threadlocal 回収 →
binding 更新でループ、それ以外の error / 正常 return はそのまま伝播。

<details>
<summary>答え骨子</summary>

上の `evalLoop` 例がそのまま答え。`catch |err| switch (err)` で特定
error だけハンドル、他は再投げ。`continue` がジャンプ命令の代用。
`pending_recur = null` を忘れずに (次の recur に備えて)。

</details>

---

## 10. 設計判断と却下した代替

| 案                              | 採否 | 理由                                                       |
|---------------------------------|------|------------------------------------------------------------|
| 10 variant を switch dispatch   | ✓    | 網羅性チェック + O(1) jump table                           |
| `eval` を `anyerror!Value` に   | ✓    | vtable error widen + Phase 3 recur 互換                    |
| `Function._pad: [6]u8` 明示     | ✓    | 8-byte alignment 保証、field 順入れ替え耐性                |
| Builtin を 48-bit fn pointer で | ✓    | alloc 0、cold start P10 に効く                            |
| Builtin を heap object (v1 初期)| ✗    | 200+ alloc、GC 対象が増える                                |
| `vtable: ?VTable` (nullable)    | ✓    | install 前後を区別、tests で mock 注入                     |
| `pub var vtable_global`         | ✗    | テスト並列性破綻 (ROADMAP §13 禁則)                        |
| `recur` を Phase 2 に含める     | ✗    | loop*/recur は Phase 3、eval signature だけ前借り          |
| closure capture を Phase 2 に   | ✗    | free variable analysis 必要、Phase 3+                      |

ROADMAP §4.4 / §4.5 / 原則 P10 (起動 sub-10ms) と整合。

---

## 11. 確認 (Try it)

```sh
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout de2cb64
zig build test
# tree_walk.zig のテスト 16 個が緑 (alignment / atoms / if / do / let* /
# def→resolve / quote / fn*→fn_val / fn 直接 call / def id then call /
# builtin / Phase-2 exit 1/2 [(let [x 1] (+ x 2)) → 3] /
# Phase-2 exit 2/2 [((fn [x] (+ x 1)) 41) → 42] / NotCallable /
# ArityMismatch)
git -C ~/Documents/MyProducts/ClojureWasmFromScratch checkout cw-from-scratch
```

Phase-2 exit criterion **両方** がここで通る:

- `(let* [x 1] (+ x 2))` → 3
- `((fn* [x] (+ x 1)) 41)` → 42

ただしこの commit 単独では builtin `+` が未 register。test 内で
**inline の `builtinPlus`** を `Env.intern` して動かす (zone 違反
回避のため)。次章 0015 で `lang/primitive` から正式 register され、
CLI からも `cljw -e "(+ 1 2)"` が動くようになる。

---

## 12. 教科書との対比

| 軸             | v1              | v1_ref       | Clojure JVM    | 本リポ                        |
|----------------|-----------------|--------------|----------------|--------------------------------|
| 行数           | 2129            | 456          | n/a            | **445**                       |
| Function 表現  | heap + GC       | heap + track | `IFn` Java cls | **heap + trackHeap**          |
| Builtin 表現   | heap object     | 48-bit ptr   | virtual call   | **48-bit fn pointer**         |
| recur 実装     | trampoline+wrap | threadlocal  | rebind+jmp     | **threadlocal (Phase 3+)**    |
| vtable 注入    | global pub var  | `*Runtime`   | n/a (compile)  | **`Runtime.vtable: ?VTable`** |

引っ張られず本リポの理念で整理した点：v1 の Builtin は heap object
だったが本リポは **48-bit fn pointer** (cold start P10)、vtable は
`pub var` global ではなく **`Runtime.vtable: ?VTable`** (§13 禁則
回避、テスト並列性 OK)、recur の threadlocal+error pattern は v1_ref
で実証済 — 本リポ Phase 3 で同じ手筋で入れる予定。

---

## 13. Feynman 課題

1. なぜ `eval` の戻り値が `anyerror!Value` なの？
2. `Function._pad: [6]u8` は何のため？
3. `Builtin` を heap object じゃなく 48-bit fn pointer にする利点は？

---

## 14. チェックリスト

- [ ] 演習 14.1: `eval` の error widen を説明できた
- [ ] 演習 14.2: `evalLet` の locals 配列遷移を予測できた
- [ ] 演習 14.3: `_pad` を消した影響を説明できた
- [ ] 演習 14.4: ArityMismatch を投げる 3 ケースを当てられた
- [ ] 演習 14.5: `initBuiltinFn` / `asBuiltinFn` を書けた
- [ ] 演習 14.6: 9 variant の eval を表を見ずに書けた
- [ ] 演習 14.7: `evalLoop` を再構成できた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout de2cb64` で `zig build test` の tree_walk が緑

---

## 次へ

第 15 章: [Primitive 群と `registerAll`](./0015-primitives-and-register.md)

— `+` `-` `*` `=` `<` `>` `nil?` `true?` `identical?` などの組込み
関数群を `lang/primitive/{math,core}.zig` に置き、`registerAll(env)`
で `rt/` 名前空間に intern、`(refer 'rt)` で `user/` から参照可能に
する。**ついに `cljw -e "(+ 1 2)"` が CLI から動く** 章。
