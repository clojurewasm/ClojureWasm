---
chapter: 9
commits:
  - 91feef0
related-tasks:
  - §9.4 / 2.1
related-chapters:
  - 0008
  - 0010
date: 2026-04-27
---

# 0009 — Runtime ハンドルと 3 層責任分割

> 対応 task: §9.4 / 2.1 / 所要時間: 90〜120 分

Phase 2 の幕を開けるコミット `91feef0` は、たった 1 コミットで 3 つの
ファイルを同時に新設します。`runtime/runtime.zig`（150 行）、
`runtime/dispatch.zig`（202 行）、`runtime/env.zig`（skeleton 80
行）の 3 つです。**バラしてコミットしたいのに、できません**。3 つの
ファイルが互いに型を参照しており、3 つそろって初めてコンパイルが
通るからです。

この章では、その「3 ファイル同時投入」の構造的な必然性と、その背後
にある **3 層（Runtime / Env / threadlocal）の責任分割**、そして v1
の経験から `pub var` ベースの dispatch を **struct field 化した理由**
を追体験します。本リポジトリの理念の核となる章です。

---

## この章で学ぶこと

- なぜ `Runtime` / `Env` / `dispatch.VTable` が **同じ commit に
  詰め込まれた** のか — import 循環とその解決
- **3 層の責任分割** (process global / per-session / per-thread) と
  各層に何を置くべきか
- v1 の `pub var callFn = undefined` を捨てて **`Runtime.vtable:
  ?VTable` field** に置き換えた経緯と利得
- Layer 0 が Layer 1+ を呼ぶ仕組み — **型だけ Layer 0、実装は起動時
  注入** という DI パターン
- `std.Io` を Runtime に詰めて全 layer に流す **0.16 の DI 哲学**

---

## 1. なぜ 3 ファイルを同時に投入したのか

Phase 2.1 の commit message にこう書いてあります。

> Implements §9.4 task 2.1. The three files have to ship in one commit
> because `dispatch.VTable` takes `*Runtime` and `*Env` and `Runtime`
> carries `vtable: ?VTable`; the import graph only compiles when all
> three files exist.

3 つのファイルの **型参照グラフ** を描くと、こうなっています。

```
runtime.zig            dispatch.zig            env.zig
─────────────          ──────────────          ──────────
const VTable           const Runtime           const Runtime
  = dispatch             = runtime               = runtime
    .VTable                .Runtime                .Runtime
                         const Env
                           = env.Env
                                              ※ skeleton。
                                                Phase 2.3 で実装が
                                                埋まる
Runtime {              VTable {                Env {
  vtable: ?VTable        callFn: *fn(            rt: *Runtime,
}                          *Runtime,             alloc: ...
                           *Env, ...           }
                           ...) ...
                       }
```

矢印にすると：

```
runtime.zig ──[VTable 型]──▶ dispatch.zig
                              │
                              ├──[*Runtime]──▶ runtime.zig (戻り)
                              │
                              └──[*Env]─────▶ env.zig

env.zig ────[*Runtime]──▶ runtime.zig
```

これは **循環参照** ですが、Zig の型システムは「同一ファイル内の型
相互参照」と同様に、**ファイル間でも型の前方宣言** を許します。ただ
し「参照先のファイルがすべて存在している」のが前提です。ファイルが
1 つでも欠けていれば全体がコンパイルできません。

つまり：

- 「`Runtime` だけ先に commit」→ `dispatch.VTable` がないので
  `vtable: ?VTable` が解決しない → コンパイルエラー
- 「`dispatch` だけ先に commit」→ `Runtime` も `Env` もないので
  関数ポインタの引数型が解決しない → コンパイルエラー
- 「`Env` だけ先に commit」→ `Runtime` がないので `rt: *Runtime` が
  解決しない → コンパイルエラー

**そのため、3 ファイル同時コミットが唯一の道です**。本リポジトリの
「TDD: red → green → refactor」の基本サイクルでは、green になる粒度
でコミットすることをルールにしているため、3 ファイルが green になる
最小単位はやはり 3 ファイル同時投入になります。

抽象的な話ではなく、3 ファイル相互参照は実際に Zig コンパイラの
挙動として観察できます。たとえば `A → C`、`B → A,C`、`C → A,B` の
3 ファイルがあるとき、A だけ commit しても C が無いので解決でき
ない、A と B を commit しても両者が C を参照するので解決できない、
3 つ同時 commit で初めてコンパイラがすべての型を見渡せて成立する、
というのがそのまま本章の状況です。

### Env は skeleton で投入する

とはいえ「3 ファイル丸ごと完全実装」を 1 コミットに押し込むと diff
が読めなくなります。そこで **Env は最小限の skeleton** で投入します:

```zig
// 91feef0 時点の env.zig (80 行)
pub const Env = struct {
    rt: *Runtime,
    alloc: std.mem.Allocator,

    pub fn init(rt: *Runtime) !Env {
        return .{ .rt = rt, .alloc = rt.gpa };
    }
    pub fn deinit(self: *Env) void { _ = self; }
};
```

これだけでも `dispatch.zig` の `*Env` 引数の型解決には十分です。
`Namespace` / `Var` / `BindingFrame` は **Phase 2.3（コミット
e20acaa）** で埋めます。詳細は第 0011 章で扱います。

---

## 2. 3 層の責任分割

Runtime / Env / threadlocal を **3 つの異なる時間軸** にマップする
のが、本リポジトリの中心設計です。

```
┌──────────────────────────────────────────────────────────────┐
│ Layer 1: Runtime          ライフタイム = プロセス全体         │
│   io: std.Io                                                  │
│   gpa: std.mem.Allocator                                      │
│   keywords: KeywordInterner                                   │
│   vtable: ?VTable                                             │
│   heap_objects: ArrayList(HeapEntry)                          │
└──────────────────────────────────────────────────────────────┘
                          ↑ 多対 1 (複数 Env が 1 つの Runtime を共有)
┌──────────────────────────────────────────────────────────────┐
│ Layer 2: Env              ライフタイム = 1 セッション         │
│   rt: *Runtime                                                │
│   alloc: std.mem.Allocator (= rt.gpa)                         │
│   namespaces: NamespaceMap   ← Phase 2.3 で埋まる             │
│   current_ns: ?*Namespace    ← *ns* の値                      │
└──────────────────────────────────────────────────────────────┘
                          ↑ 多対 1 (複数 thread が 1 つの Env を共有)
┌──────────────────────────────────────────────────────────────┐
│ Layer 3: threadlocal      ライフタイム = 1 thread             │
│   current_frame: ?*BindingFrame   (env.zig)                   │
│   last_error: ?ErrorInfo          (error.zig)                 │
│   current_env: ?*Env              (dispatch.zig)              │
│   last_thrown_exception: ?Value   (dispatch.zig)              │
└──────────────────────────────────────────────────────────────┘
```

### Runtime — process global

`Runtime` が持つのは **プロセスで 1 つしか存在しないリソース**：

| field                          | 意味                                     |
|--------------------------------|------------------------------------------|
| `io: std.Io`                   | Zig 0.16 の IO ハブ。プロセスで 1 個。   |
| `gpa: std.mem.Allocator`       | infrastructure 用 (Var / Namespace 等)。 |
| `keywords: KeywordInterner`    | キーワードプール。プロセス全体で共有。   |
| `vtable: ?VTable`              | Layer 0 → Layer 1+ の dispatch table。  |
| `heap_objects: ArrayList(...)` | Phase 5 GC 到来までの heap 解放台帳。    |

```zig
// 抜粋 — runtime.zig
pub const Runtime = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    keywords: KeywordInterner,
    vtable: ?VTable = null,
    heap_objects: std.ArrayList(HeapEntry) = .empty,

    pub fn init(io: std.Io, gpa: std.mem.Allocator) Runtime {
        return .{
            .io = io,
            .gpa = gpa,
            .keywords = KeywordInterner.init(gpa),
        };
    }
};
```

**`heap_objects` は Phase 5 mark-sweep GC が来るまでの「つなぎ」** で
す。Layer 1+ がヒープに何かオブジェクトを作ったとき、`(ptr, free_fn)`
をここに登録しておくと `Runtime.deinit` が一括で free します。
Layer 0（= `runtime.zig`）は具体的な型（例えば `tree_walk.Function`）
を **知らないまま**、関数ポインタ経由で free できます。

### Env — per-session

`Env` は **1 つのセッション** に 1 つ：

- CLI 起動 (`cljw -e ...`): プロセスの間に 1 つ
- nREPL: クライアント接続 1 個ごとに 1 つ

```zig
// Phase 2.1 (skeleton)
pub const Env = struct {
    rt: *Runtime,           // ← 後ろ向き参照
    alloc: std.mem.Allocator,
    // Phase 2.3: namespaces, current_ns ...
};
```

「Env が Runtime を指す」一方向のみで、Runtime は Env を知りません。
**この向き** が重要です。複数 Env が 1 つの Runtime を共有できるの
は、Runtime が Env のリストを持たないからです。**v1 の nREPL race
condition の直接の修正点** がここにあります。詳細は第 0011 章で
扱います。

### threadlocal — per-thread

ここに置くのは **Clojure dynamic var の意味論が要求するものだけ**：

- `current_frame: ?*BindingFrame` — `(binding [*foo* 42] body)` の
  per-thread スタック (env.zig, Phase 2.3 で実装)。
- `last_error: ?ErrorInfo` — Phase 1 で導入したエラー情報スロット。
- `current_env: ?*Env` — call 中だけ有効な「今走っている Env」。
- `last_thrown_exception: ?Value` — `(throw)` / `(catch)` の橋渡し。

ROADMAP §7.3 に明記：

> Dynamic vars stay on threadlocal. `*ns*`, `*err*`, `*print-length*`
> and friends are implemented with threadlocal binding frames. **This
> is a Clojure-semantics requirement, not incidental** — abolishing
> threadlocal is not an option.

「threadlocal は悪、撤廃すべき」ではなく、**「正しい使い方の
threadlocal がある」** ということです。Clojure の dynamic var を
threadlocal 抜きで再現すると、性能・意味論の両面で破綻します。

### どの層にどのリソースを置くか

代表的なリソースを 3 層にマップすると、判断基準（ライフタイムは
何か、共有/分離はどちらが意味論的に正しいか）が見えてきます。

| 項目                        | 配置                                  | 理由                                                               |
|-----------------------------|---------------------------------------|--------------------------------------------------------------------|
| `*ns*` の現在値             | **Env.current_ns**                    | per-session ns selector。スレッド共有でも実害なし。                |
| Murmur3 hash 関数 (純関数)  | **どれでもない**                      | 状態を持たない純関数なので、グローバル `pub fn` で OK。            |
| symbol intern table         | **Runtime.symbols** (Phase 3+)        | プロセス全体で共有 (keyword と同様)。                              |
| `(binding [*x* 1] ...)`     | **threadlocal current_frame**         | Clojure 意味論で per-thread が要件。                               |
| Mark-Sweep GC instance      | **Runtime.gc** (Phase 5+)             | プロセスで 1 つ、heap 全体を所有。                                 |
| nREPL クライアントの ns map | **Env.namespaces**                    | per-session — これが 1 つの Runtime に複数 Env がぶら下がる動機。 |
| thrown exception            | **threadlocal last_thrown_exception** | スレッドごとに独立した throw/catch chain。                         |

`*ns*` はセッション選択子なので Env、binding frame は Clojure の
意味論として per-thread が必須なので threadlocal、symbol intern や
GC instance はプロセス全体で 1 つだけ存在すべきなので Runtime と、
それぞれ素直な居場所があります。逆に「純関数の hash は層を持たない」
ことも重要で、状態を持たないものを無理に層に押し込まない節度が
3 層設計を保ちます。

---

## 3. dispatch.VTable — `pub var` を捨てた経緯

`dispatch.zig` の冒頭にこう書いてあります。

```zig
//! Why not `pub var` for the vtable? Because then tests cannot inject
//! a mock backend, and two Runtimes cannot carry different backends.
//! `Runtime.vtable: ?VTable` solves both.
```

これは **v1（89K LOC）の retrospective です**。v1 の `dispatch.zig`
は次のような形でした：

```zig
// v1 の dispatch.zig (~/Documents/MyProducts/ClojureWasm)
pub var callFn: *const fn (...) anyerror!Value = undefined;
pub var seq_fn: BuiltinFn = undefined;
pub var first_fn: BuiltinFn = undefined;
// ... 30 個ぐらいの pub var ...
pub var load_core: LoaderFn = undefined;
pub var sync_ns_var: SyncFn = undefined;
```

これは **モジュールレベルの可変グローバル変数** です。起動時に
`tree_walk` が `dispatch.callFn = &tree_walk.callFnImpl;` のように
上書きします。

### `pub var` の問題

- **テストでモックを注入できない**: `dispatch.callFn` を上書きすると
  プロセス全体に効いてしまい、並列テストが衝突します。
- **2 つの Runtime が異なる backend を持てない**: TreeWalk と VM の
  backend を 1 プロセスで共存させたい (例: `Evaluator.compare`) と
  きに、同じ `dispatch.callFn` しか持てない。
- **Zig 0.16 の DI 哲学に逆行**: 0.16 は `std.Io` も Allocator も
  「**値として渡せ**」というメッセージを stdlib 全体で発しています。
  グローバル可変変数はその真逆。
- **multi-tenant 不可**: 将来 nREPL を多接続させて backend 切替を
  サポートしようとしたら詰む。

### `Runtime.vtable: ?VTable` 解

```zig
// 本リポ — dispatch.zig
pub const VTable = struct {
    callFn: CallFn,
    valueTypeKey: ValueTypeKeyFn,
    expandMacro: ExpandMacroFn,
};

// 本リポ — runtime.zig
pub const Runtime = struct {
    // ...
    vtable: ?VTable = null,
};
```

これだけで全部解決：

| 課題             | 解                                                            |
|------------------|---------------------------------------------------------------|
| テスト時のモック | `rt.vtable = .{ .callFn = mock, ... };` で per-Runtime に注入 |
| 2 backend 共存   | `rt_a.vtable` と `rt_b.vtable` を別実装に                     |
| 0.16 DI 哲学     | 値で渡される std.Io と統一の作法                              |
| multi-tenant     | 接続ごとに Runtime を作れば自然に分離                         |

**`?VTable`** で nullable にしているのは **起動の段階性のため** です。
Phase 2.6 で TreeWalk が `installVTable(rt)` を呼ぶまでは `vtable ==
null` のままです。これは構造的な保証（= 「null の間は callFn が走らな
い」）にもなっています。

### Layer 0 → Layer 1+ の依存反転

ROADMAP §4.1 の zone 規則：

```
Layer 0 (runtime/) は Layer 1 (eval/) を import してはいけない
```

しかし TreeWalk (Layer 1) を呼びたい場面がある。例えば組み込み関数
`(map f coll)` は Layer 1 の interpreter を呼んで `f` を実行する必要
があります。

**vtable パターン** で解決：

```
Layer 0:  pub const VTable = struct { callFn: ... };  ← 型だけ
Layer 0:  pub const Runtime = struct { vtable: ?VTable };  ← 入れ物だけ

Layer 1:  pub fn callFnImpl(...) { ... }    ← 実装

main:     rt.vtable = .{ .callFn = &callFnImpl, ... };  ← 起動時注入
```

**コンパイル時の依存方向は Layer 0 から Layer 1 への呼び出しを禁止
したまま、実行時の関数呼び出しは Layer 0 → Layer 1 が成立します**。
これが依存反転（Dependency Inversion）です。

### `BuiltinFn` と `CallFn` の使い分け

`dispatch.zig` には 2 つの関数ポインタ型が並んでいます。

```zig
pub const BuiltinFn = *const fn (
    rt: *Runtime, env: *Env,
    args: []const Value, loc: SourceLocation,
) anyerror!Value;

pub const CallFn = *const fn (
    rt: *Runtime, env: *Env,
    fn_val: Value, args: []const Value,
) anyerror!Value;
```

`BuiltinFn` は `loc: SourceLocation` を取り、`fn_val` を取りません。
**呼び出し元のソース位置を受け取って、自分が組み込み実装で
あることを前提とする** シグネチャです。`+` などの組み込み関数自身が
このポインタとして登録されます。

`CallFn` は `fn_val: Value` を取り、`loc` を取りません。**任意の
callable Value（普通の `fn`、組み込み関数、multi_fn、keyword as
function 等）を一様に呼び出すディスパッチャ** です。`(map f xs)` の
中で `f` を呼ぶ場合、`f` の実体が組み込みなのか普通の `fn*` なのか
分からないので、汎用 dispatcher としての `CallFn` を経由します。

実装イメージはこうです。

```zig
fn mapImpl(rt: *Runtime, env: *Env, args: ..., loc: ...) anyerror!Value {
    const f = args[0];
    const xs = args[1];
    // ...
    const result = try rt.vtable.?.callFn(rt, env, f, &.{x});
    // ...
}
```

`map` 自身は `BuiltinFn`、内部で `vtable.callFn` を経由して `f` を
呼ぶ、というのが両者の関係です。

---

## 4. `installVTable` のタイミング — 起動の 3 段階

Phase 2 がフルに動くと、`main.zig` の起動シーケンスはこうなります
(Phase 2.6+):

```zig
pub fn main(init: std.process.Init) !void {
    // ① Runtime 構築
    var rt = Runtime.init(init.io, init.gpa);
    defer rt.deinit();

    // ② Env 構築 (rt と user namespace を作る)
    var env = try Env.init(&rt);
    defer env.deinit();

    // ③ vtable 注入 — TreeWalk を Runtime に紐付ける
    tree_walk.installVTable(&rt);

    // ④ primitive 登録 — `+`, `-`, `=` を rt namespace へ
    try primitive.registerAll(&rt, &env);

    // ... ここから Read-Analyse-Eval-Print loop ...
}
```

**順序が重要**：

1. **Runtime → Env**: Env は `rt: *Runtime` を取るので Runtime 後。
2. **Env → installVTable**: vtable 注入は Env がなくても可能だが、
   実装側 (TreeWalk) は Env が必要なケースがある (例: macro 展開)
   ので、Env が用意できた後の方が安心。
3. **installVTable → registerAll**: primitive の中に `(map f xs)` の
   ような callFn を呼ぶ実装があるため、**vtable が入っていないと
   primitive 登録時の test が落ちる可能性**。先に vtable を入れる。

この順序を 5 ステップに広げると以下になります：

```zig
var rt = Runtime.init(init.io, init.gpa);  // (1) Runtime
var env = try Env.init(&rt);               // (2) Env (rt と user ns)
tree_walk.installVTable(&rt);              // (3) vtable 注入
try primitive.registerAll(&rt, &env);      // (4) primitive を rt ns へ
const rt_ns = env.findNs("rt").?;
const user_ns = env.findNs("user").?;
try env.referAll(rt_ns, user_ns);          // (5) user ns から rt ns を refer
```

`referAll` は最後です。primitive が rt 側に揃っていないと、user
側に refer する意味がないからです。

### なぜ 91feef0 の段階では `installVTable` が呼ばれないのか

Phase 2.1 で投入された `runtime.zig` には `installVTable` 関数が
**まだ書かれていません**。なぜか：

- 2.1 時点では Layer 1（`eval/`）の TreeWalk もアナライザもまだ存在
  しません。実装がないものを注入する関数を書く意味はありません。
- 「`vtable == null` のままでも runtime は構築できる」という抽象境界
  を明示するためです。Phase 2.6 で TreeWalk が完成したときに初めて、
  `tree_walk.installVTable(rt)` が登場します。
- これは **YAGNI** ではなく **段階性** にもとづくものです。Phase 2.1
  のコミットに `installVTable` を書いてしまうと、それは「呼ぶ場所の
  ないコード」になってしまいます。

---

## 5. `std.Io` の DI 哲学

Zig 0.16 は **`std.Io` というハブ** をプロセスに 1 つ持ち、ロック /
ファイル / ネット / sleep のすべてをそこから掘り出す設計に変わり
ました。

```zig
// 旧 (Zig 0.15 まで)
var mtx: std.Thread.Mutex = .{};
mtx.lock();   // どこからでも呼べる
defer mtx.unlock();

// 新 (Zig 0.16)
var mtx: std.Io.Mutex = .init;
mtx.lockUncancelable(io);   // io が必要 — caller が持っているはず
defer mtx.unlock(io);
```

`std.Io.Mutex.lock` が `io` を引数に取るため、**lock を取るには io
が手元になければなりません**。`io` は通常 main から流れてくるもの
です。グローバル変数で済ませるのは設計のサボりです。

### Runtime に詰めて全 layer に流す

本リポは **`Runtime.io`** に詰めて全 layer に流します。例えば
`keyword.intern`:

```zig
// 第 0010 章で詳細
pub fn intern(rt: *Runtime, ns: ?[]const u8, name_: []const u8) !Value {
    rt.keywords.mutex.lockUncancelable(rt.io);   // ← rt 経由で io 取得
    defer rt.keywords.mutex.unlock(rt.io);
    return rt.keywords.internUnlocked(ns, name_);
}
```

**rt が手元にあれば io も自動的に手元にある**。これが Runtime ハンド
ルを「**全 layer の万能パスポート**」として機能させる仕組みです。

### `std.Io.Threaded` と production io

production では `init: std.process.Init` から io を取ります：

```zig
pub fn main(init: std.process.Init) !void {
    var rt = Runtime.init(init.io, init.gpa);
    // ...
}
```

test では `std.Io.Threaded.init` で組み立てる：

```zig
test "..." {
    var th = std.Io.Threaded.init(testing.allocator, .{});
    defer th.deinit();
    var rt = Runtime.init(th.io(), testing.allocator);
    defer rt.deinit();
    // ...
}
```

`std.Io` は値型 (userdata + vtable のペア、~16 bytes) なので、
**Runtime に値で持つのが安全**。逆に backing implementation
(`std.Io.Threaded` 自体) は `Runtime` に持たないこと。コメントから：

```
// Runtime stores `std.Io` **by value**. The backing implementation
// (`std.Io.Threaded`, `Io.Evented`, ...) is **not owned** by Runtime.
// We don't store the backing type because `Threaded` is move-unsafe —
// `io()` returns a `*Threaded`, and embedding `Threaded` in another
// struct would leave the userdata pointer dangling after a copy.
```

`Threaded` は move 安全ではないので Runtime のフィールドに置くと
コピー時に内部ポインタが dangle します。**呼び出し側 (main や test)
が Threaded のライフタイムを管理し、Runtime は io 値だけを持つ**。

---

## 6. Runtime — fields の意図

ファイル冒頭の doc comment が設計の意図をきれいに語っています：

```zig
//! Runtime — the process-wide handle every layer threads through.
//!
//! Three-tier architecture (see ROADMAP §4.3):
//!
//!   - **Runtime** (this file): one per process. `io`, `gpa`,
//!     interners, vtable. Lifetime = whole process.
//!   - **Env** (`env.zig`): one per CLI invocation / nREPL session;
//!     holds the namespace graph. Multiple Envs can share a Runtime
//!     (this fixes v1's nREPL session-sharing race condition).
//!   - **threadlocal** (`error.zig`, `dispatch.zig`, `env.zig`): only
//!     the per-thread state Clojure's dynamic-var semantics require.
```

### Phase ごとの field 増殖計画

```
Phase 2.1 → io / gpa / keywords / vtable / heap_objects   ← イマココ
Phase 3+ → +symbols: SymbolInterner
Phase 5+ → +gc: ?*MarkSweepGc
Phase 9+ → +interop: InterOp
Phase 14+ → 既に揃っている (nREPL は Runtime を共有して Env を分けるだけ)
```

**field を追加するのは OK、削除/改名は ADR レベル**。これがコメント
にもう書いてあります：

```
//! Adding a field is OK; renaming or removing one is an ADR-level
//! change.
```

### `heap_objects` — Phase 5 GC までの繋ぎ

Phase 5 で mark-sweep GC が来るまで、Layer 1+ の heap objects は
`Runtime.trackHeap(.{ .ptr, .free })` で登録され、`Runtime.deinit`
が一括解放します。

```zig
pub const HeapEntry = struct {
    ptr: *anyopaque,
    free: *const fn (gpa: std.mem.Allocator, ptr: *anyopaque) void,
};

pub fn trackHeap(self: *Runtime, entry: HeapEntry) !void {
    try self.heap_objects.append(self.gpa, entry);
}
```

**Layer 0 が Layer 1 の具体型を知らずに free 関数を保持できる** のが
ポイント。`tree_walk.Function` のような Layer 1 構造体を Layer 0 が
import せずに済みます。

### Runtime の輪郭

`Runtime` の公開 API は最小限です。`init(io, gpa)` で
`KeywordInterner` を作り、`vtable` は `null` で、`heap_objects` は
`std.ArrayList(HeapEntry) = .empty` で始まります。`deinit` は
`heap_objects` の各エントリを `free(gpa, ptr)` で解放してから
`heap_objects.deinit(gpa)`、最後に `keywords.deinit()` という順序
です。`trackHeap` は `heap_objects.append(gpa, entry)` のみ。
`vtable` は **デフォルト null**、起動時に `installVTable` で書き
換える、というルールが構造として表れています。

---

## 7. 設計判断と却下した代替

| 案                                     | 採否 | 理由                                                                                                                                                             |
|----------------------------------------|------|------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **3 層 (Runtime / Env / threadlocal)** | ✓   | v1 retrospective の 3 大教訓 (Env 分離 / threadlocal 集約 / per-session) を全部解決。Strategic note (`private/2026-04-24_runtime_design/`) で 4 案を比較した結論 |
| 単一巨大 `Runtime`                     | ✗   | nREPL が「Env 共有 = race」を再現する (v1 の既知バグ)                                                                                                            |
| zwasm 流 `Vm` 一本                     | ✗   | Clojure は Reader/TreeWalk/VM/REPL/nREPL 複数の execution unit があり、単一 Vm に集約できない                                                                    |
| ctx なし (io と alloc を都度引数)      | ✗   | Zig stdlib idiom 寄りで真っ当だが、シグネチャ膨張・関連 state 散逸                                                                                               |
| `pub var callFn = undefined` (v1 方式) | ✗   | Test mock 困難、Runtime ごとの vtable 切替不可、0.16 の DI 哲学に逆行                                                                                            |
| `Runtime` を Layer 1 に置く            | ✗   | Layer 0 zone (runtime/) からの import は Layer 1 から不可なので循環。Runtime は Layer 0 配下が正しい                                                             |
| `installVTable` を 91feef0 で投入      | ✗   | TreeWalk 不在。呼び出し場所のないコードは段階性違反                                                                                                              |
| 3 ファイルを別 commit に分割           | ✗   | 循環参照で各 commit がコンパイルできない (§1)                                                                                                                   |

ROADMAP §4.1 (Four-zone layered), §4.3 (Runtime + std.Io DI),
§4.4 (Dual backend), §A1 (zone deps), §A7 (concurrency Day 1),
原則 P10 (Zig 0.16 idioms) と整合。

---

## 8. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# 91feef0 時点に時計を巻き戻す
git checkout 91feef0

# 3 ファイルが揃ってコンパイル可能なことを確認
zig build test 2>&1 | grep -E "Runtime|Env|VTable" | head -10

# 個別ファイルのテストを観察
zig build test --summary new

# 戻る
git checkout cw-from-scratch
```

`91feef0` の時点で `runtime.zig` / `dispatch.zig` / `env.zig`
すべてのテストが通ること、`installVTable` が **まだ無い** ことを
確認します。

```sh
# 91feef0 時点で installVTable が無いことを確認
git show 91feef0 -- src/runtime/runtime.zig | grep -i installVTable
# ↑ 空 (= まだ存在しない)

# Phase 2.6 (de2cb64) で installVTable が登場
git log --oneline 91feef0..de2cb64 -- src/eval/backend/
```

---

## 9. 教科書との対比

| 軸             | v1 (`ClojureWasm`)                        | v1_ref                           | Clojure JVM                               | 本リポ                                  |
|----------------|-------------------------------------------|----------------------------------|-------------------------------------------|-----------------------------------------|
| dispatch table | `pub var callFn = undefined` (グローバル) | `Runtime.vtable: ?VTable` (試行) | n/a (`RT.invoke()` は static method)      | `Runtime.vtable: ?VTable` field         |
| 階層           | 2 層 (Env + threadlocal が散在)           | 3 層 試行 (Phase 2 で詰まる)     | 2 層 (`RT` static + `Var.threadBindings`) | 3 層 (Runtime / Env / threadlocal)      |
| io DI          | グローバル (Zig 0.15 時代)                | `*Runtime` (試行)                | `RT` static                               | `Runtime.io` を全 layer に流す          |
| nREPL session  | グローバル Env 共有 → race               | per-client Env (試行、未完)      | per-thread `Var` binding                  | per-client Env / Runtime 共有           |
| 起動段階性     | `dispatch.callFn = ...` を main で 30 行  | `installVTable` 試行             | `RT.init()` static initializer            | `installVTable(rt)` を Phase 2.6 で導入 |

引っ張られずに本リポジトリの理念で整理した点：

- **3 層を Day 1 から固定**: v1 は 18 ヶ月かけて 3 層に到達しました
  が、本リポジトリは Phase 2.1 の段階で型を確定させています。Field
  の追加だけで Phase 5 / 14 / 15 を迎えられる設計です。
- **`pub var` を最初から却下**: v1 retrospective、Zig 0.16 idiom、
  multi-tenant 要件の 3 つが一致した結論です。strategic note
  `private/2026-04-24_runtime_design/REPORT.md` で 5 案を比較した
  結果がこの形です。
- **3 ファイル同時投入を恥じない**: 循環 import を避けるためだけの
  分割は人工的な肥大化を生みます。**自然な責任境界が 3 ファイルに
  またがる場合は、3 ファイルを 1 コミットでまとめるのが正解です**。

---

## この章で学んだこと

- 結局この章は「**Runtime / Env / threadlocal を時間軸の長さで切り、
  Layer 0 から Layer 1 を呼ぶ橋を `Runtime.vtable: ?VTable` に置く**」
  という 1 つの設計決定の話です。
- `pub var` をやめて vtable を field 化したことで、テスト時のモック
  注入・複数 backend 共存・nREPL の per-session Env がすべて自然に
  並びます。3 ファイル同時投入は循環参照の必然であって、避けるべき
  汚れではない、と読み替えられます。

---

## 次へ

第 0010 章: [KeywordInterner を rt-aware に昇格](./0010_keyword_rt_aware.md)

— Phase 1 では module-level の mutex 風実装で済ませていた keyword
interning を、Runtime ハンドル導入の直後に **rt-aware（`rt.io` 経由
の mutex）** へリファクタリングします。なぜ Phase 2.1 と 2.2 を別
コミットにしたのか、cell layout を固定した理由、`internUnlocked`
という名前を選んだ意図を見ていきます。
