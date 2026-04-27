---
chapter: 11
commits:
  - e20acaa
related-tasks:
  - §9.4 / 2.3
related-chapters:
  - 0010
  - 0012
date: 2026-04-27
---

# 0011 — Env を完成版に — Namespace, Var, threadlocal binding frames

> 対応 task: §9.4 / 2.3 / 所要時間: 75〜105 分

Phase 2.1 で skeleton として登場した `Env`（40 行）を、Phase 2.3
（`e20acaa`）で **440 行を追加** して完成版に仕上げます。ここで初め
て「Clojure らしい」セマンティクスが本リポジトリに姿を現します。
**Namespace、Var、refer / alias、そして `(binding [*foo* 42] ...)`
のスタック** です。

中でも最も思想的に重要なのは **`current_frame` を threadlocal に置
く判断** です。これは「正しい threadlocal」であり、Clojure の dynamic
var の意味論が本質的に要請するものです。本章では、その正当性も
掘り下げます。

---

## この章で学ぶこと

- `Var` の構造 — root binding + `VarFlags` (dynamic / macro / private)
- `Namespace` の 3 つの map — `mappings` / `refers` / `aliases` の
  意味論的差
- `BindingFrame` chain と `pushFrame` / `popFrame` / `findBinding`
  による Clojure dynamic var のスタック実装
- `Var.deref` の **dynamic / 非 dynamic** 二択分岐の正当化
- `Env.init(rt)` で **`rt`** と **`user`** namespace を事前生成する
  bootstrap 設計
- threadlocal `current_frame` を使うことの **意味論的正しさ**
  (廃止可能ではない正しい threadlocal)

---

## 1. Var — root binding + flags

Clojure の `Var` は **名前付き値の入れ物** です。`(def x 42)` は
新しい `Var` を作って、`x` という名前で current namespace に登録
します。

```zig
pub const VarFlags = packed struct(u8) {
    /// `^:dynamic true` — `binding` may rebind on a per-thread frame.
    dynamic: bool = false,
    /// `^:macro` — analyzer expands the call instead of evaluating it.
    macro_: bool = false,
    /// `^:private` — not reachable from other namespaces via refer/var.
    private: bool = false,
    _pad: u5 = 0,
};

pub const Var = struct {
    ns: *Namespace,         // 所属 namespace
    name: []const u8,       // ns/name の name 部
    root: Value = .nil_val, // global root binding
    meta: ?Value = null,    // ^{...} metadata
    flags: VarFlags = .{},

    pub fn deref(self: *const Var) Value {
        if (self.flags.dynamic) {
            if (findBinding(self)) |v| return v;
        }
        return self.root;
    }

    pub fn setRoot(self: *Var, v: Value) void {
        self.root = v;
    }
};
```

3 つの flag を 1 byte に詰めるのは、Clojure JVM の `Var.java` でも
同じ思想です。Zig では `packed struct(u8)` で **1 バイトに固定して
います**。

### `^:dynamic` の意味

```clojure
(def ^:dynamic *foo* 1)

(binding [*foo* 42]
  (println *foo*))   ; → 42

(println *foo*)      ; → 1 (binding を抜けたので root)
```

`^:dynamic true` の Var は **`binding` form で per-thread に再束縛
できる**。`Var.deref` がこれを面倒見ます：

```zig
pub fn deref(self: *const Var) Value {
    if (self.flags.dynamic) {
        if (findBinding(self)) |v| return v;  // threadlocal chain
    }
    return self.root;                         // global root
}
```

**非 dynamic Var は frame を一切見ません**。ここが要点です。

### なぜ非 dynamic で frame を見ないのか

```zig
//! Non-dynamic Vars ignore frames altogether — they always return
//! `root` — so the analyzer doesn't need to special-case `let` vs
//! `binding`.
```

`(let [x 1] ...)` は `Var` を作りません。`let` のローカル binding は
analyzer/TreeWalk のローカルスコープ管理で扱われます (第 0012 章)。
一方 `(binding [*x* 1] ...)` は **`*x*` という既存の dynamic Var に
対する新しい frame** を push します。

両者を `Var.deref` の中で混ぜないために、**非 dynamic は frame を
無視する** という規約を守ります。これにより analyzer 側で「これは
let か binding か」を特別扱いせずに済みます。

### 演習 11.1: `Var.deref` の挙動 (L1 — 予測検証)

以下の状況で `v.deref()` は何を返すか予測してください。

```zig
// セットアップ
var v_static = Var{ .ns = &ns, .name = "x", .root = .nil_val };
var v_dynamic = Var{ .ns = &ns, .name = "*y*", .root = .nil_val,
                     .flags = .{ .dynamic = true } };

// frame を push
var frame: BindingFrame = .{};
try frame.bindings.put(alloc, &v_static, .true_val);
try frame.bindings.put(alloc, &v_dynamic, .false_val);
pushFrame(&frame);
defer popFrame();

// 質問
const a = v_static.deref();    // ?
const b = v_dynamic.deref();   // ?
```

Q1: `a` の値は？
Q2: `b` の値は？

<details>
<summary>答え</summary>

| 変数 | deref | 理由 |
|------|-------|------|
| `a` | `.nil_val` | `v_static` は `dynamic=false` なので **frame を見ない**。root をそのまま返す |
| `b` | `.false_val` | `v_dynamic` は `dynamic=true` なので chain を walk、frame に bind されている `.false_val` を返す |

これが「analyzer 側で let と binding を特別扱いせずに済む」設計の
具体的な現れです。frame に何を入れていようが、`Var.flags.dynamic
== false` なら無視されます。

</details>

---

## 2. Namespace — mappings / refers / aliases の 3 つの map

```zig
pub const Namespace = struct {
    name: []const u8,
    /// Vars defined here via `(def ...)`.
    mappings: VarMap = .empty,
    /// Vars pulled in via `(refer ...)`. Non-owning.
    refers: VarMap = .empty,
    /// `(require '[other :as alias])` produces these.
    aliases: NsAliasMap = .empty,

    pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
        if (self.mappings.get(name)) |v| return v;
        if (self.refers.get(name)) |v| return v;
        return null;
    }
};
```

3 つの map を **意味論的に異なる役割** で分けています。

| Map | 意味 | 所有関係 |
|------|------|----------|
| `mappings` | 自分の namespace で `(def ...)` で作った Var | **所有** (key も Var も自分が free する) |
| `refers` | 他の namespace から `(refer ...)` で取り込んだ Var | **借用** (key は所有、Var は元の ns に属する) |
| `aliases` | `(require '[ns :as a])` の `a` → 別 namespace | **借用** (key は所有、Namespace は env に属する) |

### `resolve` の lookup 順序

```zig
pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
    if (self.mappings.get(name)) |v| return v;   // ① own
    if (self.refers.get(name)) |v| return v;     // ② referred
    return null;                                  // ③ not found
}
```

これが **Clojure の lookup 順序**：

1. **自分の `def` で作ったもの** (mappings) を最優先
2. それが無ければ **refer されたもの** (refers)
3. それも無ければ `null` (analyzer/runtime 側でエラーにする)

`aliases` はこのレベルでは使いません。`(my.lib/foo bar)` のような
**修飾された symbol** が来たときだけ、alias を `aliases` から引いて
ターゲット namespace を取り、その上で `target.resolve("foo")` を
呼びます。

### 演習 11.2: `resolve` の lookup を再構成 (L2)

以下のシグネチャと test 例から、`resolve` の本体を書いてください。

```zig
pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
    // ここから書く
}

// test:
//   user.intern("x", v_user_x);
//   user.refer("y", v_other_y);
//   try expectEqual(v_user_x, user.resolve("x").?);
//   try expectEqual(v_other_y, user.resolve("y").?);
//   try expect(user.resolve("z") == null);
```

ヒント:
- `mappings.get` を最初に試す
- 次に `refers.get`
- どちらも null なら null を返す

<details>
<summary>答え</summary>

```zig
pub fn resolve(self: *Namespace, name: []const u8) ?*Var {
    if (self.mappings.get(name)) |v| return v;
    if (self.refers.get(name)) |v| return v;
    return null;
}
```

ポイント:
- **順序が意味論を担う**: `mappings` を先に見ないと、refer された同名
  Var が def を上書きしたかのような挙動になってしまいます。Clojure
  の意味論では「自分の def が勝つ」が正解です。
- **`null` 返し**: `error` を返さない理由は、呼び出し側（analyzer）
  が「special form / macro / 通常の var 解決」を順に試すためです。
  この段階で分岐させるのは早すぎます。

</details>

---

## 3. BindingFrame と threadlocal current_frame

ここが **本リポジトリで唯一の load-bearing threadlocal** です。

```zig
const BindingMap = std.AutoHashMapUnmanaged(*const Var, Value);

pub const BindingFrame = struct {
    parent: ?*BindingFrame = null,
    bindings: BindingMap = .empty,
};

pub threadlocal var current_frame: ?*BindingFrame = null;

pub fn pushFrame(frame: *BindingFrame) void {
    frame.parent = current_frame;
    current_frame = frame;
}

pub fn popFrame() void {
    if (current_frame) |f| {
        current_frame = f.parent;
    }
}

pub fn findBinding(v: *const Var) ?Value {
    var f = current_frame;
    while (f) |frame| {
        if (frame.bindings.get(v)) |val| return val;
        f = frame.parent;
    }
    return null;
}
```

### `(binding [...] body)` の実行モデル

```clojure
(def ^:dynamic *x* 1)

(binding [*x* 10]
  (binding [*x* 20]
    *x*))    ; → 20
```

これがどう動くか、stack picture で：

```
binding [*x* 10] 入る:
  current_frame ── frame_outer { parent=null, {*x*: 10} }

  binding [*x* 20] 入る:
    current_frame ── frame_inner { parent=frame_outer, {*x*: 20} }
                       │
                       parent ──▶ frame_outer { ..., {*x*: 10} }

    *x* の deref:
      findBinding walk
        frame_inner: 見つかった → 20 返す ✓

  binding [*x* 20] 抜ける:
    current_frame ← frame_inner.parent = frame_outer

binding [*x* 10] 抜ける:
  current_frame ← frame_outer.parent = null
```

**「inner frame が outer を shadow する」** という挙動は、
`findBinding` が **最初に見つかった値を返す** だけで自然に成立
します。

### なぜ threadlocal が「正しい threadlocal」なのか

ここに本リポジトリのもう 1 つの哲学があります。`docs/ja/0009-runtime-
handle-three-layers.md` で見た通り、本リポジトリは threadlocal を
最小に絞っています。

しかし `current_frame` だけは **正しい threadlocal** です。理由は
次の通りです：

1. **Clojure 意味論の要請**: `*ns*`, `*err*`, `*print-length*`,
   `*out*` などの dynamic var は **per-thread** が contract。スレッ
   ド A の `(binding [*ns* 'foo] ...)` がスレッド B に漏れてはい
   けない。
2. **`Env` レベルでは粒度が粗すぎる**: 同一 Env の中で複数スレッド
   が異なる `*ns*` 値を持ちうる。1 つの REPL session で
   future/agent がそれぞれ独自の binding を持つのが Clojure 流。
3. **Lock-free アクセス**: dynamic var の読み出しは **非常に頻繁**
   (`*ns*` は print 周りで毎回読まれる)。lock を取らずに最新値を取
   れるのが threadlocal の利点。

ROADMAP §7.3:

> Dynamic vars stay on threadlocal. `*ns*`, `*err*`, `*print-length*`
> and friends are implemented with threadlocal binding frames. **This
> is a Clojure-semantics requirement, not incidental** — abolishing
> threadlocal is not an option.

つまり「threadlocal 撲滅」ではなく、**「threadlocal を意味論で
正当化できる場所だけに残す」** という方針です。`current_frame` は
そのもっとも中核的な例です。

### v1 retrospective から

v1（89K LOC）では threadlocal が **11 個** あちこちに散在していまし
た（`io.zig` 等）。本リポジトリは strategic note（`private/2026-04-24
_runtime_design/REPORT.md`）でそれを 4 個に絞りました：

```
threadlocal:
  current_frame: ?*BindingFrame    ← Clojure binding 意味論 (正しい)
  call_stack:    ...                ← error trace (Phase 1 から)
  last_error:    ?Info             ← 同上
  current_env:   ?*Env              ← call 中だけ
```

「散らばっていた状態を集約してわかりやすくした」のではなく、
**残すべきものを 4 個に絞った** と表現するのが正確です。

### 演習 11.3: `findBinding` を chain walk で再構成 (L3)

ファイル名と公開 API のみ：

要求:
- File: `src/runtime/env.zig` の中の helper function
- Public:
  - `pub const BindingFrame = struct { parent: ?*BindingFrame, bindings: BindingMap }`
  - `pub threadlocal var current_frame: ?*BindingFrame`
  - `pub fn pushFrame(frame: *BindingFrame) void`
  - `pub fn popFrame() void`
  - `pub fn findBinding(v: *const Var) ?Value`

ヒント:
- `pushFrame` は `frame.parent = current_frame; current_frame = frame;`
- `popFrame` は `current_frame = current_frame.?.parent;` (null 判定)
- `findBinding` は while loop で chain を歩く

<details>
<summary>答え骨子</summary>

```zig
const BindingMap = std.AutoHashMapUnmanaged(*const Var, Value);

pub const BindingFrame = struct {
    parent: ?*BindingFrame = null,
    bindings: BindingMap = .empty,
};

pub threadlocal var current_frame: ?*BindingFrame = null;

pub fn pushFrame(frame: *BindingFrame) void {
    frame.parent = current_frame;
    current_frame = frame;
}

pub fn popFrame() void {
    if (current_frame) |f| {
        current_frame = f.parent;
    }
}

pub fn findBinding(v: *const Var) ?Value {
    var f = current_frame;
    while (f) |frame| {
        if (frame.bindings.get(v)) |val| return val;
        f = frame.parent;
    }
    return null;
}
```

検証: nested binding で inner frame が outer を shadow するか test:

```zig
test "nested frames shadow outer" {
    // ... v は dynamic Var ...
    var f1: BindingFrame = .{};
    try f1.bindings.put(alloc, v, .true_val);
    pushFrame(&f1);
    defer popFrame();

    var f2: BindingFrame = .{};
    try f2.bindings.put(alloc, v, .false_val);
    pushFrame(&f2);
    defer popFrame();

    try expectEqual(Value.false_val, v.deref());  // inner wins
}
```

</details>

---

## 4. Env 完成版 — bootstrap で `rt` / `user` を作る

```zig
pub const Env = struct {
    rt: *Runtime,
    alloc: std.mem.Allocator,
    namespaces: NamespaceMap = .empty,
    current_ns: ?*Namespace = null,

    pub fn init(rt: *Runtime) !Env {
        var env = Env{ .rt = rt, .alloc = rt.gpa };
        _ = try env.findOrCreateNs("rt");
        const user = try env.findOrCreateNs("user");
        env.current_ns = user;
        return env;
    }

    // findOrCreateNs / findNs / referAll / intern ...
};
```

`Env.init` が **2 つの namespace を予め作る**:

| Namespace | 役割 |
|-----------|------|
| `rt` | kernel primitives の置き場。Phase 2.7 で `+` / `-` / `=` 等が `(def +) ...` で登録される |
| `user` | デフォルトの eval target。`current_ns = user` |

### なぜ `rt` と `user` を bootstrap で作るか

3 つの理由：

1. **「primitive を `rt/+` として登録」設計の前提**: ROADMAP §9.4 task
   2.7 で `primitive.registerAll(rt, env)` が呼ばれるが、その時 `rt`
   namespace が既に存在しないと register できない。
2. **`user` が REPL の入口**: `cljw -e "(+ 1 2)"` の評価は **user**
   namespace で起きる。最初から `current_ns` が `user` でないと、
   どこに評価コンテキストを置くべきかが宙に浮く。
3. **`(refer 'rt)` を Phase-2 boot で実行できるように**: user に
   いる状態で `+` を unqualified に書くには、user の `refers` に rt
   の Var が入っている必要がある。`Env.init` 後に `referAll(rt_ns,
   user_ns)` が走る。

### `referAll` — 1 namespace の全 mappings を refer

```zig
pub fn referAll(self: *Env, from: *Namespace, to: *Namespace) !void {
    var it = from.mappings.iterator();
    while (it.next()) |entry| {
        if (to.refers.contains(entry.key_ptr.*)) continue;  // idempotent
        const owned_key = try self.alloc.dupe(u8, entry.key_ptr.*);
        errdefer self.alloc.free(owned_key);
        try to.refers.put(self.alloc, owned_key, entry.value_ptr.*);
    }
}
```

要点：

- **`to.refers` への登録**: Var の所有権は `from.mappings` に残し、
  `refers` 側は借用のみとして扱います。
- **idempotent**: すでに refer されていれば skip します。同じ
  `referAll` を 2 回呼んでも 2 重登録にはなりません。
- **key の dup**: `from.mappings` の key と `to.refers` の key は
  別 string にしています。これにより各 namespace が独立に解放
  できます。

### Clojure 4.x の `(refer 'rt)` と本リポの差

Clojure JVM では `(refer 'clojure.core)` が standard です。本リポ
ジトリでは Phase 2 の段階で、**rt namespace に primitive を集約する**
設計を採っています：

- Phase 2: `rt/+`、`rt/-`、`rt/=`（低レベル primitive のみ）
- Phase 3+: `clojure.core/defn` や `clojure.core/when` などの macro
  が Clojure 側で定義され、`clojure.core` namespace に置かれます。

`rt` という名前は **「runtime kernel — Zig 側で実装された primitive
が住む特別な場所」** を意図しています。Clojure JVM の `clojure.core`
と analogous ですが、後者は Clojure code で書かれているのに対し、
本リポジトリの `rt` は Zig code（BuiltinFn）で書かれているという点
が本質的な違いです。

### 演習 11.4: `Env.intern` を REPL-idempotent に書く (L2)

`(def x 1)` を 2 回呼んだら、Var pointer は **同じ** であってほしい
(REPL の挙動)。本体を書いてください。

```zig
pub fn intern(self: *Env, ns: *Namespace, name: []const u8, root: Value) !*Var {
    // ヒント:
    //  - もし ns.mappings に name が既にあれば、その Var の root を更新して既存ポインタを返す
    //  - 無ければ new Var を作って put、ポインタを返す
}
```

<details>
<summary>答え</summary>

```zig
pub fn intern(self: *Env, ns: *Namespace, name: []const u8, root: Value) !*Var {
    if (ns.mappings.get(name)) |existing| {
        existing.root = root;     // update in place
        return existing;
    }
    const owned_name = try self.alloc.dupe(u8, name);
    errdefer self.alloc.free(owned_name);
    const v = try self.alloc.create(Var);
    errdefer self.alloc.destroy(v);
    v.* = .{ .ns = ns, .name = owned_name, .root = root };
    try ns.mappings.put(self.alloc, owned_name, v);
    return v;
}
```

ポイント:

- **update in place**: 同名 Var が既にあれば、新しい Var を作らない。
  pointer 同一性が保たれるので、他の場所から `*Var` を保持してい
  るコードがそのまま動く (e.g. analyzer がキャッシュしていた
  Var)。
- **errdefer で半端な状態を防ぐ**: name dup → fail なら早期 return、
  Var create → fail なら name を free、map.put → fail なら Var を
  destroy。
- **Clojure JVM `Var.intern` と整合**: Clojure も同じ方針 (内部
  ConcurrentHashMap で putIfAbsent)。

</details>

---

## 5. Two Envs sharing a Runtime — nREPL race fix

`Env` の根幹的な設計目的は、**複数の独立した namespace 空間を 1 つの
Runtime 上に共存させる** ことです。

```zig
test "Two Envs sharing a Runtime have isolated namespaces" {
    var fix: TestFixture = undefined;
    fix.init(testing.allocator);
    defer fix.deinit();

    var env1 = try Env.init(&fix.rt);
    defer env1.deinit();
    var env2 = try Env.init(&fix.rt);
    defer env2.deinit();

    const user1 = env1.findNs("user").?;
    _ = try env1.intern(user1, "x", .true_val);

    const user2 = env2.findNs("user").?;
    try testing.expect(user2.resolve("x") == null);   // ← isolated
}
```

`env1.intern(user, "x", ...)` が `env2.user` に漏れません。
**これが v1 で起きていた nREPL race の修正点です**。

### v1 の問題

v1 は **process global Env** を 1 個持っていました。すると：

```
nREPL client A:  (in-ns 'foo) → *ns* = foo
nREPL client B:  (in-ns 'bar) → *ns* = bar (... shared!)
nREPL client A:  *ns*           ← 'bar が返る (B が上書き)
```

`*ns*` は threadlocal にあったため多少は緩和されていましたが、
**Var を作る `(def x ...)` は global namespace map** に書き込まれる
ので、A の def が B からも見えてしまう（汚染）状況になっていました。

### 本リポの解決

```
client A → Env_A → namespaces { user, ... }
client B → Env_B → namespaces { user, ... }   (independent)
              \    /
            shared Runtime { keywords, vtable, ... }
```

- **per-client Env**: namespace map もそれぞれ独立
- **shared Runtime**: keyword pool / dispatch table はプロセスで 1 つ
  (これは共有しても問題ない、というかむしろ共有したい)

ROADMAP §7.1 の concurrency mapping（Phase 14: nREPL）と整合して
います。strategic note の「案 2（3 層 Runtime / Env / threadlocal）」
がここで本領を発揮します。

---

## 6. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| **3 つの map (mappings / refers / aliases)** + threadlocal binding | ✓ | Clojure 意味論を 1:1 で写す。lookup 順序も自然 |
| 単一 map で「どこから来たか」フラグを持つ | ✗ | 所有関係 (own / borrow) が混ざり、deinit が複雑になる |
| `current_frame` を Env に持つ | ✗ | スレッド A の frame がスレッド B から見える。Clojure 意味論違反 |
| `current_frame` を完全に廃止 | ✗ | dynamic var を実装する別手段が無い (lock + map なら遅い) |
| `Var.deref` で常に frame を walk | ✗ | 非 dynamic Var のホットパス (= ほとんどの var) が無駄に lookup する |
| `(def x ...)` で常に新 Var を作る | ✗ | REPL での再 def で既存参照が無効化される。Clojure JVM と非互換 |
| `Env.init` で `rt` / `user` を作らない | ✗ | analyzer / primitive register 側に bootstrap 責任が散る |
| Env が Runtime を所有 (逆向き back ref) | ✗ | 複数 Env の Runtime 共有が不可能になる (nREPL race fix が無効) |
| Var を Value (NaN-boxed) として扱う | △ | Phase 4+ で `var_ref` slot を使う予定だが、Phase 2 では `*Var` ポインタで OK |

ROADMAP §4.3 (Runtime + std.Io DI), §7.3 (Dynamic vars stay on
threadlocal), §A7 (Concurrency designed Day 1), Clojure JVM の
`Var.java` / `Namespace.java` と整合。

---

## 7. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# Phase 2.3 時点
git checkout e20acaa

# Env 関連の test 全部
zig build test 2>&1 | grep -E "Env|Var|Namespace|BindingFrame" | head -20

# Phase 2.1 (skeleton) と 2.3 (完成版) の差を見る
git diff 91feef0 e20acaa -- src/runtime/env.zig | head -60

# 戻る
git checkout cw-from-scratch
```

`91feef0`〜`e20acaa` の env.zig は **+440 行 / -45 行**。skeleton
(40 行) → 完成版 (476 行) という 10 倍以上の肥大化が、**意味論の
網羅** ゆえに正当化されることを diff で確認できます。

```sh
# nested binding の動作確認 (Phase 2.6 完了後の HEAD で)
zig build test --summary new 2>&1 | grep "BindingFrame"
```

---

## 8. 教科書との対比

| 軸 | v1 (`ClojureWasm`) | v1_ref | Clojure JVM | 本リポ |
|----|--------------------|--------|-------------|--------|
| Env 単位 | process global | per-session (試行) | n/a (RT は static) | per-session (`Env`) |
| Var の場所 | `runtime/var.zig` 単独ファイル | `Env` 内 | `clojure.lang.Var` | `runtime/env.zig` 内 |
| dynamic binding | threadlocal `binding_stack` (ad-hoc) | threadlocal `current_frame` (試行) | `Var.dvals` thread-local | threadlocal `current_frame` (chain) |
| flag 表現 | `dynamic: bool` ばらばら field | `VarFlags` (試行) | `Var.dynamic` boolean + `Var.macroFlag` etc. | `VarFlags` packed `u8` |
| refer 意味論 | `referrals: HashMap` | `refers` (試行) | `Namespace.refers` | `refers: VarMap` (key 所有, Var 借用) |
| nREPL race | **あり**: shared Env | per-client Env (試行、未完) | per-thread Var binding | **解決済**: per-client Env |
| `Env.init` の bootstrap | グローバル global init | `rt` ns 作成 (試行) | `clojure.core` を JVM init で load | `rt` + `user` を `Env.init` で create |
| `(def x ...)` 再 def | 常に新 Var | update in place (試行) | `Var.bindRoot` で in-place | update in place |

引っ張られずに本リポジトリの理念で整理した点：

- **3 つの map を意図的に分ける**: v1 / Clojure JVM の「`mappings` /
  `refers` / `aliases`」という 3 軸構造を踏襲しつつ、**所有関係
  （own / borrow）** を Zig の allocator-aware なスタイルで明示
  しています。
- **threadlocal の最小化**: v1 の 11 個に対し、本リポジトリは 4 個
  まで絞り込んでいます。残した 4 個は **すべて意味論的に正当化
  できます**（dynamic var / error trace / call current env / thrown
  exception）。
- **per-session Env で nREPL race を Day 1 から fix**: Phase 14 で
  nREPL を実装する際にも、再設計なしで `spawn(handler, .{rt,
  env_per_client})` を呼ぶだけで済むよう、土台が Phase 2 の段階で
  完成しています。

---

## 9. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. なぜ `^:dynamic` の Var だけが `current_frame` を walk して、非
   dynamic の Var は walk しないのか。1 行で。
2. なぜ `Namespace` は `mappings` と `refers` を別の map に分けて
   いるのか。1 行で。
3. なぜ `current_frame` は **正しい threadlocal** であり、廃止すべき
   ではないと言えるのか。1 行で。

---

## 10. チェックリスト

- [ ] 演習 11.1 の `Var.deref` 予測検証で正解できる
- [ ] 演習 11.2 の `Namespace.resolve` をシグネチャだけから書ける
- [ ] 演習 11.3 で `pushFrame` / `popFrame` / `findBinding` をゼロから
      書き起こせる
- [ ] 演習 11.4 で REPL-idempotent な `Env.intern` を書ける
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout e20acaa` で `zig build test` が緑になることを確認
- [ ] v1 の nREPL race と本リポの per-session Env による解決を 2-3 行で
      説明できる

---

## 次へ

第 0012 章: [Form を Node に — Analyzer が作る AST](./0012-analyzed-ast-node.md)

— Phase 2.4 で導入される `eval/node.zig` の `Node` tagged union を
追体験します。Phase 1 の `Form`（= ソース構文の生 AST）と、Phase 2
の `Node`（= 解析済み AST）の責任分離が主題です。`let*` のローカル
binding 番号付けや、`fn*` のクロージャキャプチャ解析を初めて扱う
段階に入ります。
