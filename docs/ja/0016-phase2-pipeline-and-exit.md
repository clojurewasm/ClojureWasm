---
chapter: 16
commits:
  - 8d32c83
  - 7d9fe5f
related-tasks:
  - §9.4 / 2.10
  - §9.4 / 2.11
related-chapters:
  - 0015
  - "—"
date: 2026-04-27
---

# 0016 — Phase 2 RAEP パイプラインと exit gate

> 対応 task: §9.4 / 2.10–2.11 / 所要時間: 60〜90 分

ここまでに作ってきた **Reader**（第 12 章）、**Analyzer**（第 13
章）、**TreeWalk**（第 14 章）、**primitives**（第 15 章）。**すべて
の層** を `main.zig` で wire し、`cljw -e "(+ 1 2)"` が `3` を返す
世界を **ここで閉じる** のがこの章です。続けて、**Phase 2 の exit
criterion を shell script で pin する** ことで、後の Phase で誰かが
壊しても CI が即座に検知してくれる **executable spec** を導入します。

ここが **Phase 2 教材の最終章** です。読み終わると `(let* [x 1]
(+ x 2))` が動く **最小限の Clojure** が手元に成立します。

---

## この章で学ぶこと

- **RAEP**: Read-Analyse-Eval-Print の 4 段階を `main.zig` でどう繋ぐか
- 起動順 `Runtime.init → Env.init → installVTable → registerAll` の依存方向
- `printValue` が **Phase-2 surface（atomic 値のみ）** をどう扱い、heap kind を `#<tag>` で先送りするか
- arena allocator を per-eval で切らずに **1 回だけ使う** 選択
- なぜ exit criterion を **shell script** で固定するか
- Phase 2 → Phase 3 への **橋渡し**

---

## 1. Phase 1 の `main.zig` から RAEP へ

第 11 章で Reader を CLI に繋いだ時点では、main は **Read-Print**
だけだった：

```zig
// Phase 1 main.zig (eead562 時点) — 抜粋
var reader = Reader.init(arena, expr.?);
while (try reader.read()) |form| {
    try form.format(stdout);    // pr-str of the parsed Form
    try stdout.writeByte('\n');
}
```

これは「**パーサが正しいか目視できる**」ためだけの暫定形。
Phase 2 の `8d32c83` で main は **Read-Analyse-Eval-Print** に
昇格する：

```zig
// Phase 2 main.zig (8d32c83 時点) — 抜粋
var rt = Runtime.init(io, gpa);
defer rt.deinit();
var env = try Env.init(&rt);
defer env.deinit();

tree_walk.installVTable(&rt);
try primitive.registerAll(&env);

var reader = Reader.init(arena, expr.?);
while (true) {
    const form_opt = reader.read() catch |err| {
        try stderr.print("Read error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    const form = form_opt orelse break;

    const node = analyzeForm(arena, &rt, &env, null, form) catch |err| {
        try stderr.print("Analyse error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
    const result = tree_walk.eval(&rt, &env, &locals, node) catch |err| {
        try stderr.print("Eval error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try printValue(stdout, result);
    try stdout.writeByte('\n');
}
```

4 段階が 1 ループに同居：

```
   ┌────────┐    ┌──────────┐    ┌────────┐    ┌────────┐
   │ Read   │ → │ Analyse  │ → │ Eval   │ → │ Print  │
   │ Form   │    │ Node     │    │ Value  │    │ stdout │
   └────────┘    └──────────┘    └────────┘    └────────┘
```

各段で error が起きると **stderr に書いて exit 1**。これは P6
(Error quality is non-negotiable) の **暫定形** — `@errorName(err)`
だけ表示する。Phase 3 task 3.1 で `<file>:<line>:<col>` 込みの本格
P6 報告に置き換える予定（章末で予告）。

### 演習 16.1: 起動順を空で列挙する (L1 — 穴埋め)

```zig
var rt = ____.init(io, gpa);
defer rt.deinit();

var env = try ____.init(&rt);
defer env.deinit();

____.installVTable(&rt);          // (a)
try ____.registerAll(&env);       // (b)
```

Q1: 空欄に入る型 / モジュール名は？
Q2: (a) と (b) の順序を入れ替えると、どんなテストが落ちる？
Q3: なぜ `Env.init` が `*Runtime` を必要とするのか？

<details>
<summary>答え</summary>

**Q1**:

```zig
var rt = Runtime.init(io, gpa);
var env = try Env.init(&rt);
tree_walk.installVTable(&rt);
try primitive.registerAll(&env);
```

**Q2**: `installVTable` を後に置くと `tree_walk.eval` の呼び出しが
**vtable を介さない**ため、`Function` heap 値（fn* で作る closure）
の呼び出しが panic になる。`((fn* [x] (+ x 1)) 41)` のテストが落ちる。

**Q3**: `Env` は `*Runtime` を `.rt` フィールドに保持し、
`Namespace` の allocator や `KeywordInterner` を runtime 経由で取る。
**Runtime が parent、Env がその下のレイヤ**という依存関係。

</details>

---

## 2. printValue — Phase 2 surface のみ

`printValue` は `main.zig` の **暫定実装**。Phase 2 が扱える値の
範囲だけを正しく印字する：

```zig
pub fn printValue(w: *Writer, v: Value) Writer.Error!void {
    switch (v.tag()) {
        .nil => try w.writeAll("nil"),
        .boolean => try w.writeAll(if (v.asBoolean()) "true" else "false"),
        .integer => try w.print("{d}", .{v.asInteger()}),
        .float => {
            const f = v.asFloat();
            if (std.math.isNan(f)) try w.writeAll("##NaN")
            else if (std.math.isPositiveInf(f)) try w.writeAll("##Inf")
            else if (std.math.isNegativeInf(f)) try w.writeAll("##-Inf")
            else try w.print("{d}", .{f});
        },
        .char => try w.print("\\u{x:0>4}", .{v.asChar()}),
        .builtin_fn => try w.writeAll("#builtin"),
        .keyword => {
            const k = keyword.asKeyword(v);
            try w.writeByte(':');
            if (k.ns) |n| { try w.writeAll(n); try w.writeByte('/'); }
            try w.writeAll(k.name);
        },
        else => |t| try w.print("#<{s}>", .{@tagName(t)}),
    }
}
```

### 2.1 なぜ heap kind は `#<list>` placeholder か

Phase 2 では heap collection（list / vector / map）は **まだ存在
しない**。primitive を呼ぶときの `args` slice は analyzer が直接
`[]Value` を作るため heap を経由しない。よって `printValue` が
heap 型に出会うのは **builtin_fn を返す primitive を直接 print**
するレアケースのみ。

将来 Phase 3 で list / vector が入ったら、`else => |t| #<{s}>` の
枝が当たり始める。そこで **`runtime/print.zig` に切り出して本格
`pr-str` を実装**するのが §9.5 task 3.8 の予定。

### 2.2 `##NaN`, `##Inf`, `##-Inf` の特別処理

Clojure (1.9+) は IEEE-754 の特殊値を **読める形** で印字する：

```clojure
(/ 1.0 0.0)    ;=> ##Inf
(/ 0.0 0.0)    ;=> ##NaN
```

`{d}` フォーマットは `inf` / `nan` のような **ホスト依存の表記**を
出すので、Clojure 互換に明示的に分岐。これは小さな細部だが、
**「pr-str した結果が再度 read できる」**という Clojure の不変
条件を Phase 2 から守るため。

---

## 3. arena allocator — per-eval で切らない選択

Phase 1 の main.zig 以来、arena は **process-lifetime arena**
（`init.arena.allocator()`）を 1 回だけ取って、reader / analyzer /
node 全員に渡している：

```zig
const arena = init.arena.allocator();
...
var reader = Reader.init(arena, expr.?);
...
const node = analyzeForm(arena, &rt, &env, null, form) catch |err| { ... };
```

`-e` で渡される expression は **CLI プロセスが終わるまで生きる**
ので、per-eval で arena を `.deinit()` して掃除する意義が薄い。
**プロセス終了でまとめて捨てる**方が単純で速い。

これは ROADMAP **P5 (do not optimise prematurely)** の典型応用：

> 速度・容量の最適化は **動くものができてから測定して** やる。
> Phase 2 の cljw は対話 REPL ではないので、メモリの長期 fragmentation
> を心配する必要が無い。

将来 REPL（Phase 3+）が来たら、各 form ごとに per-eval arena を切る
かどうかは別途設計事項。本章の時点では **「動くものを最短で」**。

### 演習 16.2: RAEP の error path を書く (L2 — 部分再構成)

シグネチャだけ与える：

```zig
fn raepStep(
    reader: *Reader,
    rt: *Runtime,
    env: *Env,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
) !bool {
    // 仕様:
    //   - reader.read() で form を取る。null なら return false。
    //   - error は "Read error: <name>\n" を stderr に出して exit 1。
    //   - analyzeForm / tree_walk.eval も同様。
    //   - 結果を printValue で stdout に出して return true。
}
```

ヒント: `tree_walk.MAX_LOCALS` 個の local slot を
`[_]Value{.nil_val} ** N` で初期化。error 時 exit は
`std.process.exit(1)`。

<details>
<summary>答え</summary>

```zig
fn raepStep(
    reader: *Reader,
    rt: *Runtime,
    env: *Env,
    arena: std.mem.Allocator,
    stdout: *Writer,
    stderr: *Writer,
) !bool {
    const form_opt = reader.read() catch |err| {
        try stderr.print("Read error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };
    const form = form_opt orelse return false;

    const node = analyzeForm(arena, rt, env, null, form) catch |err| {
        try stderr.print("Analyse error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    var locals: [tree_walk.MAX_LOCALS]Value = [_]Value{.nil_val} ** tree_walk.MAX_LOCALS;
    const result = tree_walk.eval(rt, env, &locals, node) catch |err| {
        try stderr.print("Eval error: {s}\n", .{@errorName(err)});
        try stderr.flush();
        std.process.exit(1);
    };

    try printValue(stdout, result);
    try stdout.writeByte('\n');
    return true;
}
```

ポイント:

1. **3 段の error path が同じ shape**。Phase 3 task 3.2-3.4 で
   `setErrorFmt` 経由の P6 統合に置き換えると、3 つとも単一の
   `printError(stderr, rt.last_error)` に畳まれる。
2. `locals` 配列は **stack 上**。`tree_walk.MAX_LOCALS` が固定なので
   heap 取得は不要。
3. `try stderr.flush()` を **exit 前に必ず**呼ぶ：buffered な
   stderr は flush 忘れで黙ってしまう。

</details>

---

## 4. Phase 2 exit gate — executable spec

`8d32c83` で main が動いた瞬間、ROADMAP §9.4 の **exit criterion**
が満たされたかを **shell script で pin する** のが `7d9fe5f`。

### 4.1 exit criterion の 3 ケース

`test/e2e/phase2_exit.sh` の核心：

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

run_case() {
    local label="$1" expr="$2" want="$3"
    local got
    got=$("$BIN" -e "$expr" 2>&1) || {
        echo "✗ $label: cljw exited non-zero" >&2
        exit 1
    }
    if [[ "$got" != "$want" ]]; then
        echo "✗ $label" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        exit 1
    fi
    echo "    ✓ $label"
}

run_case "(+ 1 2)"                "(+ 1 2)"               "3"
run_case "(let* [x 1] (+ x 2))"   "(let* [x 1] (+ x 2))"  "3"
run_case "((fn* [x] (+ x 1)) 41)" "((fn* [x] (+ x 1)) 41)" "42"
```

3 ケースが Phase 2 の **守備範囲を網羅**：

| ケース | 検証する機能 |
|--------|------------|
| `(+ 1 2)` → `3` | RAEP 最短経路。primitive call が動く |
| `(let* [x 1] (+ x 2))` → `3` | local binding (slot allocation) |
| `((fn* [x] (+ x 1)) 41)` → `42` | closure (Function heap) と function call |

### 4.2 なぜ executable spec か

代替案を 3 つ考えると本質が見える：

**A: textual な exit criterion を ROADMAP に書くだけ** — 問題は
**ドリフト**。半年後に誰かが `+` を変えても、ROADMAP は静的なテキスト
なので **検出されない**。CI も走らない。

**B: zig test で `expectEqualStrings`** — 問題は `main.zig` を
経由しないこと。**CLI 全体（arg parsing + RAEP + stdout flush）が
含まれない**。

**C: bash script で実バイナリを叩く ✓** 採用案。**`zig build` を
毎回走らせ、`zig-out/bin/cljw -e '...'` の出力を文字列比較**。
CLI まで含めた end-to-end の検証が 1 ファイルに収まる。

### 4.3 `test/run_all.sh` への配線

```bash
echo "==> 1. zig build test"
zig build test

echo "==> 2. zone_check --gate"
bash scripts/zone_check.sh --gate

echo "==> 3. e2e: Phase-2 exit criteria"
bash test/e2e/phase2_exit.sh        # ← 追加
```

これで **「コミット前に必ず緑」** という unified gate に Phase 2
の exit criterion が組み込まれた。**ROADMAP §11.6 (gate timeline)**
で Active gate に昇格。これが緑になった瞬間が **Phase 2 完了の
正式な印**。

### 演習 16.3: phase2_exit.sh をゼロから書き起こす (L3 — 完全再構成)

要求:
- File: `test/e2e/phase2_exit.sh`
- 仕様:
  - リポルートに cd
  - `zig build` を走らせて `zig-out/bin/cljw` を作る
  - `cljw -e '<expr>'` の stdout を文字列比較
  - 3 ケース: `(+ 1 2)` → `3`, `(let* [x 1] (+ x 2))` → `3`,
              `((fn* [x] (+ x 1)) 41)` → `42`
  - ✗ 表示は label / want / got を含める
  - 全 OK で "Phase-2 exit-criterion e2e: all green." を出す
  - `set -euo pipefail` を使う

<details>
<summary>答え骨子</summary>

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

BIN="zig-out/bin/cljw"
zig build >/dev/null

if [[ ! -x "$BIN" ]]; then
    echo "✗ binary missing: $BIN" >&2
    exit 1
fi

run_case() {
    local label="$1" expr="$2" want="$3"
    local got
    got=$("$BIN" -e "$expr" 2>&1) || {
        echo "✗ $label: cljw exited non-zero" >&2
        exit 1
    }
    if [[ "$got" != "$want" ]]; then
        echo "✗ $label" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        exit 1
    fi
    echo "    ✓ $label"
}

run_case "(+ 1 2)"                "(+ 1 2)"                "3"
run_case "(let* [x 1] (+ x 2))"   "(let* [x 1] (+ x 2))"   "3"
run_case "((fn* [x] (+ x 1)) 41)" "((fn* [x] (+ x 1)) 41)" "42"

echo
echo "Phase-2 exit-criterion e2e: all green."
```

ポイント:

1. `set -euo pipefail` で **どれか 1 つでも非ゼロ exit したら即終了**。
2. `2>&1` で **stderr もキャプチャ**：CLI が「Read error: ...」を
   stderr に書いたケースも検出される。
3. `-e` で渡す式に shell 特殊文字（`!`, `*foo*`, `` ` ``）を含めない
   こと（`.claude/rules/cljw-invocation.md` 参照）。3 ケースとも安全。

</details>

---

## 5. 設計判断と却下した代替

| 案 | 採否 | 理由 |
|----|------|------|
| 案 A: textual exit criterion を ROADMAP に書くだけ | ✗ | 検証が不可能。ドリフトを CI が検知できない |
| 案 B: zig test 内の `expect_equal` で確認 | ✗ | `main.zig` の arg parsing / stdout flush / RAEP wiring が含まれず end-to-end にならない |
| 案 C: bash script で実バイナリを叩く | ✓ | 採用。CLI の build → run → 出力比較を CI で再現可能 |
| 案 D: per-eval で arena をリセット | ✗ | Phase 2 は対話 REPL ではないので fragmentation 不要。**P5** |
| 案 E: `printValue` を別ファイル `runtime/print.zig` に最初から | ✗ | Phase 2 ではほぼ atomic 値しか印字しない。Phase 3.8 で list / vector が来てから切り出す（**A2**） |
| 案 F: error path を `setErrorFmt` 経由で P6 統合 | ✗ | Phase 2 は `@errorName` で簡易表示。本格 P6 は §9.5 task 3.1-3.4（過剰設計を避ける） |

ROADMAP §9.4 / 2.10 (RAEP wiring), 2.11 (exit gate), §11.6 (gate
timeline), §A2, §P5, §P6 と整合。

---

## 6. 確認 (Try it)

```sh
cd ~/Documents/MyProducts/ClojureWasmFromScratch

# RAEP が動く時点
git checkout 8d32c83
zig build
./zig-out/bin/cljw -e "(+ 1 2)"
# → 3
./zig-out/bin/cljw -e "(let* [x 1] (+ x 2))"
# → 3
./zig-out/bin/cljw -e "((fn* [x] (+ x 1)) 41)"
# → 42

# Phase 2 exit gate が pin される時点
git checkout 7d9fe5f
bash test/e2e/phase2_exit.sh
# → ✓ (+ 1 2)
#   ✓ (let* [x 1] (+ x 2))
#   ✓ ((fn* [x] (+ x 1)) 41)

bash test/run_all.sh
# → 全 3 suite green

git checkout cw-from-scratch
```

---

## 7. 教科書との対比

| 軸 | v1 (`ClojureWasm`) | v1_ref | Clojure JVM | 本リポジトリ |
|----|---------------------|--------|-------------|---------|
| main.zig 構造 | 200+ 行、複数モード（REPL / -e / -f） | RAEP は別ファイル | `Main.java` 数千行 | RAEP を main.zig 内 inline、177 行 |
| eval engine | bytecode VM が default | TreeWalk のみ | bytecode VM | TreeWalk のみ（Phase 11 で VM 追加） |
| exit gate | clj test suite + bash | 部分的に shell | 巨大な JUnit suite | 3 ケースの bash script |
| arena 戦略 | per-eval split + GC | per-eval | full GC | process-lifetime 1 回 |
| printValue | `runtime/print.zig` 数百行 | 別ファイル | `RT.print()` reflective | main.zig に暫定 inline、Phase 3.8 で切り出し |

引っ張られずに本リポジトリの理念で整理した点：

- v1 は **多モード CLI**（REPL / `-e` / `-f` / `--socket`）を Day 1
  から積んでいましたが、本リポジトリは **Phase 2 では `-e` のみ**
  に絞っています。**P5** に沿って、必要になった時点で増やす方針です。
- Clojure JVM は exit criterion を JUnit で持っていますが、本リポ
  ジトリは **shell script** で済ませます。`zig test` を不要にし、CI
  環境を最小に保つためです。
- v1 の `printValue` は早い段階から大きなファイルになっていました
  が、本リポジトリは **inline で書き、必要になったら切り出す** と
  いう progressive な配置にしています。

---

## 8. Feynman 課題

6 歳の自分に説明するつもりで答えてください。

1. **Phase 1 の main.zig と Phase 2 の main.zig の違いは何か**。1 行で。
2. **exit criterion を shell script にした理由は何か**。1 行で。
3. **arena を per-eval で切らないのに困らないのはなぜか**。1 行で。

---

## 9. チェックリスト

- [ ] 演習 16.1: 起動順 4 ステップを即答できる
- [ ] 演習 16.2: RAEP の error path をシグネチャだけから書けた
- [ ] 演習 16.3: phase2_exit.sh をゼロから書き起こせた
- [ ] Feynman 3 問を 1 行ずつで答えられた
- [ ] `git checkout 7d9fe5f` の状態で `bash test/run_all.sh` を緑にできた
- [ ] `cljw -e "((fn* [x] (+ x 1)) 41)"` が `42` を返すことを目視確認

---

## Phase 2 まとめ — ここまでで何が出来上がったか

教科書としての Phase 2 の物語を 3 行でまとめると：

- **Phase 1** で **データ**（Value、Form）と **読み**（Tokenizer、
  Reader）を作りました。
- **Phase 2** で **解釈**（Analyzer、TreeWalk）と **基本演算**
  （math、core）を加えました。
- これで `cljw -e "(let* [x 1] (+ x 2))"` が動く **最小限の
  Clojure** が成立します。

NaN boxing、threadlocal `last_error`、Runtime / Env / Namespace、
Tokenizer、Reader、Form、Node、slot allocation、BindingFrame、
TreeWalk、Function（closure）、math primitives、core predicates、
registerAll、RAEP。**これらすべての層が機能している** ことを、3 つの
shell test ケースが保証しています。

---

## 次へ

Phase 3 — defn と例外処理の章群

`§9.5` の task が並ぶ：

- **§9.5 task 3.1**: `error_print` + `cljw` invocation 改修（P6 有効化）
- **§9.5 task 3.2-3.4**: Reader / Analyzer / TreeWalk が `setErrorFmt` 経由で Info を threadlocal `last_error` に積むように
- **§9.5 task 3.5-3.6**: String / List heap type
- **§9.5 task 3.7**: `macro_transforms.zig`（`let`, `when`, `cond`, `->`, `->>` 等）
- **§9.5 task 3.8**: `runtime/print.zig` 切り出し
- **§9.5 task 3.9-3.11**: `try` / `catch` / `throw` / `loop` / `recur` + closure capture
- **§9.5 task 3.12-3.14**: `bootstrap.zig` + `core.clj` Stage 1 + exit smoke

Phase 3 が完了すると、`(defn f [x] (+ x 1)) (f 2)` が **マクロ展開
込み** で動くようになり、`(try ... (catch ExceptionInfo e ...))`
でエラーを捕捉できる **Clojure の小さな完成版** が手に入ります。

第 17 章は Phase 3 task 3.1-3.4 の **error 表示の本格運用** から
始まる — 教科書で言えば「error 報告は Day 1 から本気でやる」を真に
実現する章。お楽しみに。
