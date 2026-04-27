---
chapter: 15
commits:
  - f81f97a
  - 8d0c677
  - 04e84bf
related-tasks:
  - §9.4 / 2.7
  - §9.4 / 2.8
  - §9.4 / 2.9
related-chapters:
  - 0014
  - 0016
date: 2026-04-27
---

# 0015 — Primitives と registerAll

> 対応 task: §9.4 / 2.7–2.9 / 所要時間: 60〜90 分

`(+ 1 2)` が `3` を返すためには、ホスト言語（Zig）の **実体のある
関数** が `+` というシンボルから引けるようになっている必要があります。
本章では **math primitives**（`+ - * = < > <= >=` と `compare`）、
**core predicates**（`nil?`、`true?`、`false?`、`identical?`）、
そして 1 行の `registerAll(env)` で `rt/` 名前空間に詰め込み、
`user/` に refer する **起動コード** を扱います。

3 つのコミットを 1 章にまとめているのは、これらが **「素の builtin を
生やす」** という同一の概念を 3 段階で完成させるためです。math だけ、
core だけ、registerAll なし、のいずれが欠けても動きません。

---

## この章で学ぶこと

- **BuiltinFn** シグネチャ `fn(*Runtime, *Env, []const Value, SourceLocation) anyerror!Value` の各引数の役割
- **Float-contagion** と **integer overflow → float promotion**
- `pairwise` で `< > <= >= =` を **1 ループに畳む**：N-ary 比較セマンティクス
- **identity element**：`(+ )` は `0`、`(* )` は `1`、`(- )` は `ArityException`
- core predicate が **NaN-boxed Value の bit 比較のみ** で済む — allocation も vtable detour も無し
- **registerAll** が math + core を束ね、Phase 3+ で **`try X.register(...)` 1 行**で拡張可能

---

## 1. BuiltinFn と math primitives

`primitive/math.zig` の各関数は同じ署名を持つ：

```zig
pub fn plus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt;
    _ = env;
    _ = loc;
    try ensureNumeric(args);
    if (args.len == 0) return Value.initInteger(0);     // identity element
    if (anyFloat(args)) {                                // float contagion
        var sum: f64 = 0.0;
        for (args) |v| sum += toF64(v);
        return Value.initFloat(sum);
    }
    var sum: i64 = 0;
    for (args) |v| sum += toI64(v);
    return Value.initInteger(sum);                       // overflow → promote
}
```

これが `runtime/dispatch.zig` の `BuiltinFn` 型エイリアス。4 つの
引数の役割：

| 引数 | 用途 |
|------|------|
| `rt: *Runtime` | アロケータ / Io / vtable へのアクセス |
| `env: *Env` | namespace / Var の参照 |
| `args: []const Value` | 評価済みの実引数。NaN-boxed `u64` slice |
| `loc: SourceLocation` | エラー時の `<file>:<line>:<col>` 報告用 |

Phase 2 の `+` は rt / env / loc を使わず `_ = ...;` で discard。
**「使わない」と明示**することで、将来使うようになった差分が
追いやすい。

### 1.1 Identity element の慣習

```
(+)   → 0          (* 加算の単位元 *)
(*)   → 1          (* 乗算の単位元 *)
(-)   → ArityException   (* 負号には単位元が無い *)
```

`(reduce + [])` が `0` で初期化するのは `+` の identity element
が `0` だから。実装上は `if (args.len == 0) return Value.initInteger(0);`
の 1 行で表現される。`(- )` だけが ArityException なのは、`(- 5)`
が negate (`-5`)、`(- 5 3)` が subtract (`2`) と意味が違うため
**0 引数では未定義**なため。

### 1.2 Float-contagion

混在 (int + float) は **f64 に拡幅**。`anyFloat(args)` の **1 ビット
判定**で path を切り替える：

```zig
fn anyFloat(args: []const Value) bool {
    for (args) |v| {
        if (v.tag() == .float) return true;
    }
    return false;
}
```

### 1.3 Integer overflow → float promotion

i48 の範囲（±140 兆）を超えたら **自動的に f64 へ promote**。
これは `Value.initInteger` の側で行われる（第 2 章で見た
overflow フォールバック）。math.zig は **何も書かない** —
正しさは Value 型の責務に委譲。**P3 (core stays stable)** の好例。

```
(+ 9223372036854775000 1000)
  ↓ i64 加算 (sum = 9223372036854776000、i48 範囲外)
  ↓ Value.initInteger(sum) が initFloat にフォールバック
→ 9.223372036854776e18
```

### 演習 15.1: `+` を identity element から書き起こす (L2 — 部分再構成)

シグネチャだけ与える：

```zig
pub fn plus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    // 仕様:
    //   - args.len == 0  → (+) は 0
    //   - すべて integer → i64 加算 (overflow は initInteger 任せ)
    //   - 1 つでも float → f64 contagion
    //   - 数値以外 → error.TypeError
}
```

ヒント: `ensureNumeric(args)` を最初。`anyFloat(args)` で path
分岐。`toF64(v)` / `toI64(v)` で取り出し。

<details>
<summary>答え</summary>

```zig
pub fn plus(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    try ensureNumeric(args);
    if (args.len == 0) return Value.initInteger(0);
    if (anyFloat(args)) {
        var sum: f64 = 0.0;
        for (args) |v| sum += toF64(v);
        return Value.initFloat(sum);
    }
    var sum: i64 = 0;
    for (args) |v| sum += toI64(v);
    return Value.initInteger(sum);
}
```

ポイント:

1. `ensureNumeric` を **最初**に呼んで、後段の `unreachable` を回避。
2. **identity element `0`** は args.len == 0 の早期 return。
3. `anyFloat` 分岐で同じループを 2 つ書く（contagion）。共通化
   すると速度が落ちるので避ける。
4. overflow promotion を `Value.initInteger` に委ねる **P3** の典型。

</details>

---

## 2. 比較 — pairwise で N-ary を畳む

Clojure の `<` は N-ary：`(< 1 2 3 4)` は「1 < 2 かつ 2 < 3 かつ
3 < 4」。これを **pairwise ループ + short-circuit**で実装：

```zig
fn pairwise(args: []const Value, comptime pred: fn (a: f64, b: f64) bool) !Value {
    try ensureNumeric(args);
    if (args.len < 2) return Value.true_val;   // (< 1) も (<) も true
    if (anyFloat(args)) {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (!pred(toF64(args[i - 1]), toF64(args[i]))) return Value.false_val;
        }
    } else {
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const a = toI64(args[i - 1]);
            const b = toI64(args[i]);
            if (!pred(@floatFromInt(a), @floatFromInt(b))) return Value.false_val;
        }
    }
    return Value.true_val;
}

fn pLT(a: f64, b: f64) bool { return a < b; }
fn pEQ(a: f64, b: f64) bool { return a == b; }
// ... pGT, pLE, pGE も同様

pub fn lt(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    return pairwise(args, pLT);
}
```

この一つのループが `< > <= >= =` の **5 primitive で共有**。違いは
`pred` だけ。`comptime pred: fn(...)` は **Zig の comptime 関数引数**
で、各 caller のために `pairwise` が specialize される — ランタイム
オーバーヘッドはゼロ、まるで `pred` が直接 inline されたように動く。

### なぜ i64 でも f64 経由で比較するのか

i48 値は f64 にロスレスに収まるので、`pred` を **f64 専用に 1 種類
だけ定義**すれば全部済む。i64 専用 pred を書くと 2 倍のコード
だが、片方の道で速度差もキャッシュ差も発生しないため、**保守の
単純さで f64 統一**を選択。

---

## 3. Core predicates — bit 比較のみ

`primitive/core.zig` は **わずか 4 関数 + 80 行**。なぜそんなに
小さいか — **NaN-boxed Value の bit 比較で全部済む**から：

```zig
pub fn nilQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    try requireArity(args, 1);
    return if (args[0].isNil()) .true_val else .false_val;
}

pub fn trueQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    try requireArity(args, 1);
    return if (args[0] == Value.true_val) .true_val else .false_val;
}

pub fn identicalQ(rt: *Runtime, env: *Env, args: []const Value, loc: SourceLocation) anyerror!Value {
    _ = rt; _ = env; _ = loc;
    try requireArity(args, 2);
    return if (args[0] == args[1]) .true_val else .false_val;
}
```

`Value` は `enum(u64)` の non-exhaustive enum。`==` は **u64 同士の
1 命令比較**。allocation も vtable detour も発生しない。

### 3.1 `(true? 1)` は **false**

Clojure の **truthiness** と **`true?` の strict 判定**は別物：

| 述語 | 通る値 |
|------|--------|
| `(if x ...)` truthy | `nil` と `false` 以外すべて（`0`, `""`, `[]`, `:foo` も真） |
| `(true? x)` strict | `true` (`Value.true_val`) のみ |
| `(false? x)` strict | `false` (`Value.false_val`) のみ |
| `(nil? x)` strict | `nil` (`Value.nil_val`) のみ |

```clojure
(true? 1)       ; → false  (truthy だが true? ではない)
(false? nil)    ; → false  (falsy だが false? ではない)
(nil? false)    ; → false  (false は nil ではない)
```

これは Clojure の **意図的な区別**。`if` の判定（truthiness）と
「値そのものが true / false / nil か」（identity）を混同しない
よう、3 述語が分離されている。

### 3.2 `(identical? :foo :foo)` → true

```clojure
(identical? :foo :foo)   ; → true
```

`identical?` は bit 等価。それでも `:foo :foo` が true なのは
**keyword interning** が成立しているから（第 6 章の `KeywordInterner`
の単一スロット）。**同じ keyword リテラルは同一の NaN-boxed bit
pattern**。

### 演習 15.2: 述語の挙動を予測する (L1 — 予測検証)

```clojure
(nil? nil)              ; → ?
(nil? false)            ; → ?
(nil? 0)                ; → ?
(true? true)            ; → ?
(true? 1)               ; → ?
(false? nil)            ; → ?
(false? false)          ; → ?
(identical? :a :a)      ; → ?
(identical? 1 1)        ; → ?
```

<details>
<summary>答え</summary>

| 式 | 値 | 理由 |
|----|-----|-----|
| `(nil? nil)` | `true` | nil singleton |
| `(nil? false)` | `false` | false は nil_val ではない |
| `(nil? 0)` | `false` | i48 0 は nil_val ではない |
| `(true? true)` | `true` | true_val |
| `(true? 1)` | `false` | truthy だが true_val ではない |
| `(false? nil)` | `false` | nil は false_val ではない |
| `(false? false)` | `true` | false_val |
| `(identical? :a :a)` | `true` | keyword interning で同一 bit |
| `(identical? 1 1)` | `true` | i48 で同じ値は同じ bit pattern |

`(identical? 1 1)`: Clojure JVM では small-int キャッシュの効き
方で実装依存だが、本リポジトリは **NaN-boxed i48 そのものが値**なので
**必ず同じ u64**。よって常に true。

</details>

---

## 4. registerAll — 起動の orchestrator

`primitive.zig` は **わずか 50 行（テスト除く）**。役割は 3 つ：

```zig
pub fn registerAll(env: *Env) !void {
    const rt_ns = env.findNs("rt") orelse return RegisterError.RtNamespaceMissing;
    const user_ns = env.findNs("user") orelse return RegisterError.UserNamespaceMissing;

    try math.register(env, rt_ns);
    try core.register(env, rt_ns);

    try env.referAll(rt_ns, user_ns);
}
```

1. `rt` namespace を取得
2. 各モジュールの `register(env, rt_ns)` を呼んで `rt/+` 等を intern
3. `env.referAll(rt, user)` で `user/` から見えるようにする

### 4.1 `rt/` と `user/` が分かれる理由

| 名前空間 | 住人 | 解決経路 |
|----------|-----|---------|
| `rt/` | host-implemented primitives | 直接 intern |
| `user/` | ユーザコード（REPL デフォルト） | `refers: rt → user` |

`user` プロンプトで `(+ 1 2)` と書くと `user/+` を resolve →
refers をたどって `rt/+` の Var に到達 → BuiltinFn を呼ぶ。
**Clojure JVM の `clojure.core/+` と完全に並行**。

### 4.2 Idempotent — 再実行で重複しない

```zig
test "registerAll is idempotent" {
    try registerAll(&env);
    const refer_count = user_ns.refers.count();
    try registerAll(&env);
    try testing.expectEqual(refer_count, user_ns.refers.count());
}
```

`Env.intern` も `Env.referAll` も **既存名を上書きしない / skip
する**。REPL で `(in-ns 'user)` 後に再起動しないでも安全。

### 4.3 Phase 3+ の拡張点 — 1 行追加

```zig
try math.register(env, rt_ns);
try core.register(env, rt_ns);
try seq.register(env, rt_ns);    // ← Phase 3 で 1 行
```

**A2 (新機能は新ファイル)** の典型。新しい primitive ファイルは：

1. `src/lang/primitive/<name>.zig` を作る
2. `ENTRIES` 配列に primitive を並べる
3. `pub fn register(env: *Env, rt_ns: *Namespace) !void` を 1 つ書く
4. `primitive.zig` の registerAll に `try X.register(...)` を 1 行

これだけ。**起動コードが個々の primitive の中身を知らない** ので、
新ファイル追加が既存コードに波及しない。

### 演習 15.3: registerAll をゼロから書き起こす (L3 — 完全再構成)

要求:
- File: `src/lang/primitive.zig`
- Public API:
  - `pub const RegisterError = error{ RtNamespaceMissing, UserNamespaceMissing, OutOfMemory };`
  - `pub fn registerAll(env: *Env) !void;`
- 仕様:
  - rt / user namespace を見つける（無ければ error）
  - math と core を rt に register
  - rt から user に referAll
  - 2 回呼んでも user.refers の count が変わらない

<details>
<summary>答え骨子</summary>

```zig
//! Primitive registration entry point.

const std = @import("std");
const env_mod = @import("../runtime/env.zig");
const Env = env_mod.Env;

const math = @import("primitive/math.zig");
const core = @import("primitive/core.zig");

pub const RegisterError = error{
    RtNamespaceMissing,
    UserNamespaceMissing,
    OutOfMemory,
};

pub fn registerAll(env: *Env) !void {
    const rt_ns = env.findNs("rt") orelse return RegisterError.RtNamespaceMissing;
    const user_ns = env.findNs("user") orelse return RegisterError.UserNamespaceMissing;

    try math.register(env, rt_ns);
    try core.register(env, rt_ns);

    try env.referAll(rt_ns, user_ns);
}

test "registerAll installs every Phase-2 primitive in rt/" {
    // ... setup Runtime + Env ...
    try registerAll(&env);
    const rt_ns = env.findNs("rt").?;
    try std.testing.expect(rt_ns.resolve("+") != null);
    try std.testing.expect(rt_ns.resolve("nil?") != null);
}
```

検証: `bash test/run_all.sh` が緑になる。

</details>

---

## 5. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| 案 A: builtin を `Function` heap struct と同じく heap allocate | ✗ | 48-bit fn pointer で表現できる（NaN-boxing tag `0xFFFF`）、heap 不要。GC も避けられる |
| 案 B: math と core を 1 ファイル `primitive.zig` に | ✗ | 将来 seq / pred / io / str / num が増えると 1000 行越え必至。**A6** 違反 |
| 案 C: registerAll を `main.zig` に inline | ✗ | 起動コードが builtin の中身を知ることになる。zone layering 違反 |
| 案 D: comptime StaticStringMap で primitive table | ✗ | Phase 2 では数が少なく `for (ENTRIES)` の方が読みやすい。**P5 (do not optimise prematurely)** |
| 案 E: `pairwise` を hand-unroll で `<` 専用に | ✗ | 5 primitive で 5 倍のコード。`comptime pred` で specialize されるのでオーバーヘッドゼロ |

ROADMAP §9.4 / 2.7 (math), 2.8 (math 続き), 2.9 (core), §A2,
§A6, §P5 と整合。

---

## 6. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# math primitives が入った時点
git checkout f81f97a
zig build test 2>&1 | tail -5
# → primitive/math.zig のテスト群が緑

# core predicates も加わる
git checkout 8d0c677
zig build test 2>&1 | tail -5
# → primitive/core.zig のテストも追加で緑

# registerAll で env に届く
git checkout 04e84bf
zig build test 2>&1 | tail -5
# → primitive.zig のテスト 4 つ追加で緑

git checkout cw-from-scratch
```

`zig build run` で実バイナリは動かせるが、**CLI が RAEP 経由で
primitive を呼ぶ**のは次章 (`8d32c83`) なので、ここではテストでの
動作確認のみ。

---

## 7. 教科書との対比

| 軸 | v1 (`ClojureWasm`) | v1_ref | Clojure JVM | 本リポジトリ |
|----|---------------------|--------|-------------|---------|
| primitive 表現 | heap-allocated `Function` 構造体 | host fn pointer | `Symbol` → `Var` → `IFn.invoke()` | NaN-boxed builtin_fn (48-bit ptr) |
| registry | `core_lib_<group>.zig` 多数 | `lang/core_*.zig` | `clojure/core.clj` (Clojure 自身) | `lang/primitive/<topic>.zig` + `registerAll` |
| float-contagion | i64 / f64 で別 fn 生成 | path 分岐 | `Numbers.add(Object, Object)` reflective | `anyFloat` 1 ビット判定で path 分岐 |
| `nil?` 実装 | discriminant 比較 | bit 比較 | `(nil? x) == (== x nil)` | bit 比較 (`Value.true_val == ...`) |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は primitive を heap に置いていたため、**GC roots への登録**
  が必要でした。本リポジトリは **48-bit fn ptr** で表現するので、
  GC を経由しません。
- v1 の `core_lib_<group>` 接頭辞を、**`primitive/<topic>.zig`** に
  改めてレイヤ語を明示しています。
- Clojure JVM は **`clojure.core` そのものが `.clj` ファイル** で、
  JVM intrinsic だけが Java で書かれています。本リポジトリは
  **Phase 3 で `core.clj` Stage 1**（macro layer）を導入する予定で、
  それまでは **すべて Zig 側で実装します**。

---

## 8. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. **`(+)` が `0` で `(*)` が `1` なのに、`(-)` がエラーになるのは
   なぜか**。1 行で。
2. **`(true? 1)` と `(if 1 :a :b)` の結果はどう違うか**。1 行で。
3. **`registerAll` を 2 回呼んでも環境が壊れないのはなぜか**。1 行で。

---

## 9. チェックリスト

- [ ] 演習 15.1: `+` の N-ary を identity element から書き起こせた
- [ ] 演習 15.2: 9 つの述語式の真偽値を全問正解
- [ ] 演習 15.3: `registerAll` をファイル名と API リストだけから書けた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout 04e84bf` の状態で `zig build test` を緑にできた

---

## 次へ

第 16 章: [Phase 2 RAEP パイプラインと exit gate](./0016-phase2-pipeline-and-exit.md)

— Phase 2 の **完成編** です。`main.zig` を Read-Print から
**Read-Analyse-Eval-Print** に昇格させ、`test/e2e/phase2_exit.sh`
で 3 つの exit criterion を CLI 経由で pin します。`(let* [x 1]
(+ x 2))` が `3` を返す瞬間を見届けます。
