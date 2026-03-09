# ClojureWasm 最終設計書

> 2026-03-08. 03/04 ドキュメントの監査結果を統合した最終設計書。
> CW (89K LOC), Clojure JVM, ClojureScript, Kiso の参照実装を再検証し、
> 実装順序・ディレクトリ構造・責務分離・拡張性・ユーザー体験を最適化。

---

## 目次

1. [設計哲学と原則](#1-設計哲学と原則)
2. [ディレクトリ構造: 完成形](#2-ディレクトリ構造-完成形)
3. [Layer 0: runtime/](#3-layer-0-runtime)
4. [Layer 1: eval/](#4-layer-1-eval)
5. [Layer 2: lang/](#5-layer-2-lang)
6. [Layer 3: app/](#6-layer-3-app)
7. [modules/ モジュールシステム](#7-modules-モジュールシステム)
8. [Phase 実装順序（監査済み）](#8-phase-実装順序監査済み)
9. [ユーザー体験設計](#9-ユーザー体験設計)
10. [最適化戦略の集約](#10-最適化戦略の集約)
11. [品質管理とテスト戦略](#11-品質管理とテスト戦略)
12. [CW 教訓の設計反映チェックリスト](#12-cw-教訓の設計反映チェックリスト)

---

## 1. 設計哲学と原則

### 1.1 ユーザー（開発者自身）の価値観

01_myself_audit.md から抽出した不可侵の原則:

| #  | 原則                    | 設計への影響                                     |
|----|-------------------------|--------------------------------------------------|
| P1 | 理解しながら進める      | Claude Code 対話型。一晩自動実行しない           |
| P2 | 完成形を最初に見通す    | ディレクトリ・ファイル構成を Day 1 で確定        |
| P3 | コアは安定              | 一度作ったら変更不要。拡張は modules/ に閉じる   |
| P4 | 「都度対応」の忌避      | 散発パッチではなく構造的解決                     |
| P5 | モジュラリティ          | 必要な機能のみバイナリに含める（modules/ + comptime flags） |
| P6 | エラー品質最優先        | file, ns, line, col, 周辺コード, 色, stack trace |
| P7 | upstream 忠実性は非制約 | 実用性優先。互換性は modules/ 経由                |
| P8 | cljw バイナリ主体       | 一つのバイナリで REPL, nREPL, 評価, build, js    |

### 1.2 アーキテクチャ原則

| #  | 原則                                      | 検証方法                                      |
|----|-------------------------------------------|-----------------------------------------------|
| A1 | 下位層は上位層を知らない                  | zone_check.sh --gate (CI ゲート)              |
| A2 | 機能追加は既存コードをいじらない          | ModuleDef + comptime flags                    |
| A3 | 最適化コードは明確に分離                  | src/eval/optimize/ に集約                     |
| A4 | GC は独立したサブシステム                 | gc/arena.zig, gc/mark_sweep.zig, gc/roots.zig |
| A5 | テストは実装と鏡像構造                    | test/ が src/ を反映                          |
| A6 | 各ファイル 1,000 行以下（ソフトリミット） | CW collections.zig 6K LOC の二の舞防止        |
| A7 | 並行性・エラーは Day 1 から設計に組込み   | threadlocal, SourceLocation, mutex            |

### 1.3 CW からの教訓（設計に反映済み）

| CW の問題                             | ClojureWasm (新) の対策              | 検証セクション |
|---------------------------------------|--------------------------------------|----------------|
| カーネル 410+ 関数に肥大化            | ~160 関数。残りは .clj               | §5             |
| core.clj を独自記述で車輪の再発明     | upstream core.clj を rt/ 置換で適応  | §5.3           |
| NaN Boxing を Phase 35 で後付け       | Day 1 から NaN Boxing                | §3.1           |
| 並行性を Phase 48 で 15 ファイル改修  | Day 1 から threadlocal + mutex       | §3.6           |
| エラーに SourceLocation なし          | Day 1 から全 Form に loc             | §3.7           |
| GC ルート追跡漏れ（D100）             | suppress_count, HeapHeader mark bit  | §3.4           |
| builtins/collections.zig が 6K LOC    | primitive/, collection/ に意味分割   | §5.2           |
| 拡張性なし（WASM/regex がコア埋込み） | modules/ + ModuleDef + comptime flags | §7            |
| nREPL がアプリ層に密結合              | app/repl/ サブディレクトリに整理     | §6.2           |

---

## 2. ディレクトリ構造: 完成形

**P2（完成形を最初に見通す）** に基づき、全 Phase 完了時のディレクトリを確定する。
Phase 1 から全ディレクトリ・ファイルをプレースホルダーで用意し、
以降は **ファイル追加なし、内容のみ実装** が理想。

```
ClojureWasm/
├── src/
│   ├── runtime/                    [Layer 0] 値・コレクション・GC・環境
│   │   ├── value.zig               NaN Boxing Value 型 (u64)
│   │   ├── hash.zig                Murmur3 ハッシュ
│   │   ├── env.zig                 Namespace, Var, 動的束縛フレーム
│   │   ├── dispatch.zig            vtable (下位→上位の関数ポインタ)
│   │   ├── error.zig               エラー型・ヘルパー・フォーマッタ
│   │   ├── keyword.zig             キーワードインターン (mutex 付き)
│   │   ├── module.zig              ModuleDef インターフェース
│   │   ├── gc/                     GC サブシステム
│   │   │   ├── arena.zig           Arena GC インターフェース
│   │   │   ├── mark_sweep.zig      Mark-Sweep GC (Phase 5 末で実装)
│   │   │   └── roots.zig           ルートセット定義 + 型別マーク走査
│   │   └── collection/             永続データ構造
│   │       ├── list.zig            PersistentList (cons cell) + ArrayMap
│   │       ├── hamt.zig            HAMT (PersistentHashMap, PersistentHashSet)
│   │       └── vector.zig          PersistentVector (32-way trie + tail)
│   │
│   ├── eval/                       [Layer 1] Reader・Analyzer・Backend
│   │   ├── form.zig                Form 構造体定義 + SourceLocation
│   │   ├── tokenizer.zig           字句解析 (テキスト → トークン)
│   │   ├── reader.zig              構文解析 (トークン → Form)
│   │   ├── node.zig                Node tagged union 定義
│   │   ├── analyzer.zig            意味解析 (Form → Node AST)
│   │   ├── backend/                実行バックエンド
│   │   │   ├── tree_walk.zig       AST 直接評価器
│   │   │   ├── compiler.zig        バイトコードコンパイラ
│   │   │   ├── opcode.zig          opcode enum + メタデータ
│   │   │   ├── vm.zig              スタックベース VM
│   │   │   └── evaluator.zig       デュアルバックエンド + compare()
│   │   ├── cache/                  バイトコードキャッシュ
│   │   │   ├── serialize.zig       バイトコードシリアライズ (CWNC)
│   │   │   └── generate.zig        ビルド時キャッシュ生成
│   │   └── optimize/               最適化（明確に分離）
│   │       ├── peephole.zig        ピープホール最適化 (Phase 13)
│   │       ├── super_instruction.zig スーパーインストラクション融合 (Phase 17)
│   │       ├── jit_arm64.zig       ARM64 JIT (Phase 20)
│   │       └── jit_x86_64.zig      x86_64 JIT (Phase 20 stretch)
│   │
│   ├── lang/                       [Layer 2] Primitives・Bootstrap・Interop
│   │   ├── primitive.zig           プリミティブ登録エントリポイント
│   │   ├── primitive/              rt/ プリミティブ実装
│   │   │   ├── core.zig            コア (apply, type, identical?)
│   │   │   ├── seq.zig             シーケンス (first, rest, cons, seq, next)
│   │   │   ├── coll.zig            コレクション (assoc, dissoc, get, conj, count)
│   │   │   ├── math.zig            算術 (+, -, *, /, mod, rem, compare)
│   │   │   ├── string.zig          文字列 (str, subs, string?)
│   │   │   ├── pred.zig            述語 (nil?, number?, keyword?, fn?)
│   │   │   ├── io.zig              IO (println, pr, prn, slurp, spit)
│   │   │   ├── meta.zig            メタデータ (meta, with-meta, vary-meta)
│   │   │   ├── ns.zig              名前空間 (in-ns, require, refer, alias)
│   │   │   ├── atom.zig            参照型 (atom, deref, swap!, reset!)
│   │   │   ├── protocol.zig        Protocol/Multimethod 操作
│   │   │   ├── error.zig           エラー (ex-info, ex-message, ex-data)
│   │   │   ├── regex.zig           正規表現 (re-find, re-matches, re-seq)
│   │   │   └── lazy.zig            遅延 (lazy-seq, realized?)
│   │   ├── bootstrap.zig           7 段階ブートストラップ実行
│   │   ├── interop.zig             Java Interop クラスレジストリ
│   │   ├── ns_loader.zig           NS ローダー (ファイル解決)
│   │   ├── macro_transforms.zig    Zig レベルマクロ変換 (ns, defmacro)
│   │   └── clj/                    埋め込み .clj ソース
│   │       ├── clojure/
│   │       │   ├── core.clj        ~600 defn/defmacro (upstream 適応)
│   │       │   ├── string.clj      clojure.string
│   │       │   ├── set.clj         clojure.set
│   │       │   ├── walk.clj        clojure.walk
│   │       │   ├── zip.clj         clojure.zip
│   │       │   ├── edn.clj         clojure.edn
│   │       │   ├── test.clj        clojure.test
│   │       │   └── pprint.clj      clojure.pprint
│   │       └── cljs/
│   │           ├── analyzer.clj    CLJS アナライザ
│   │           ├── emitter.clj     CLJS → JS エミッタ
│   │           ├── env.clj         CLJS コンパイル環境
│   │           ├── resolver.clj    CLJS NS 解決
│   │           └── core.cljs       CLJS コアマクロ
│   │
│   ├── app/                        [Layer 3] CLI・REPL・nREPL・Builder
│   │   ├── cli.zig                 CLI 引数パーサー + ディスパッチ
│   │   ├── runner.zig              実行エンジン (エラー出力の責務)
│   │   ├── repl/
│   │   │   ├── repl.zig            REPL メインループ
│   │   │   ├── line_editor.zig     行編集 (readline 互換)
│   │   │   ├── nrepl.zig           nREPL サーバー (TCP, bencode)
│   │   │   └── bencode.zig         bencode エンコーダ/デコーダ
│   │   ├── builder.zig             シングルバイナリ生成
│   │   └── deps.zig                deps.edn パーサー + 依存解決
│   │
│   └── main.zig                    エントリポイント
│
├── modules/                        optional modules (comptime フラグで有効/無効)
│   ├── math/                       clojure.math
│   │   ├── module.zig              ModuleDef
│   │   └── builtins.zig            45 数学関数
│   ├── c_ffi/
│   │   ├── module.zig              ModuleDef
│   │   └── exports.zig             C ABI エクスポート
│   └── wasm/
│       ├── module.zig              ModuleDef
│       ├── builtins.zig            Wasm 操作
│       └── wasm.clj                cljw.wasm NS
│
├── test/                           テスト (src/ 鏡像構造)
│   ├── runtime/                    Layer 0 ユニットテスト
│   ├── eval/                       Layer 1 ユニットテスト
│   ├── lang/                       Layer 2 統合テスト
│   ├── app/                        Layer 3 E2E テスト
│   ├── clj/test_core.clj           Clojure レベルテスト
│   └── e2e/run_e2e.sh              E2E テストランナー
│
├── build.zig                       ビルドスクリプト
├── build.zig.zon                   パッケージ定義
├── flake.nix                       Nix 開発環境
├── bench/                          ベンチマーク (Phase 8+)
│   ├── bench.sh                    統一エントリポイント (run/record/compare)
│   ├── history.yaml                ベースライン記録
│   ├── compare.yaml                クロス言語比較スナップショット
│   └── suite/                      ベンチマークスイート
│       └── NN_name/                各ベンチマーク (meta.yaml + bench.clj)
├── scripts/
│   ├── zone_check.sh               ゾーン依存チェッカー
│   └── coverage.sh                 vars カバレッジレポート
│
├── .dev/                           開発管理
│   ├── design/                     設計ドキュメント
│   ├── status/vars.yaml            vars 実装追跡
│   ├── known_issues.md             既知問題
│   ├── memo.md                     セッションハンドオーバー
│   └── roadmap.md                  Phase トラッカー
│
└── .claude/                        Claude Code 設定
    ├── CLAUDE.md                   プロジェクトルール
    ├── references/                 参照ドキュメント
    └── rules/                      自動ロードルール
```

### 2.1 現行構造からの変更点

| 変更                                   | 理由                                              |
|----------------------------------------|---------------------------------------------------|
| Reader を 3 ファイルに分割             | CW で実証済み: tokenizer/reader/form の責務分離   |
| Analyzer + Node を追加                 | 特殊形式のディスパッチに tagged union Node が必要 |
| lang/primitive/ ディレクトリに 15 分割 | CW collections.zig 6K LOC 問題の回避              |
| eval/optimize/ ディレクトリ追加        | 最適化コードの明確な分離 (A3)                     |
| runtime/gc/ サブディレクトリ           | GC アルゴリズムの独立性 (A4)                      |
| runtime/collection/ サブディレクトリ   | collection 肥大化防止                             |
| app/repl/ サブディレクトリ             | REPL + nREPL + line_editor の整理                 |
| app/runner.zig 追加                    | CLI とエラー出力の責務分離                        |
| app/deps.zig 追加                      | deps.edn 解決ロジックの独立                       |
| macro_transforms.zig 追加              | ns マクロ等の Zig レベル変換を明示化              |
| keyword.zig 分離                       | キーワードインターンのスレッド安全性管理          |

### 2.2 ファイル数の比較

| レイヤー     | CW (現行) | ClojureWasm (新)    | 備考                          |
|--------------|-----------|---------------------|-------------------------------|
| runtime/     | 18        | 13                  | GC 分離、HAMT/Vector 分離     |
| eval/        | 18        | 15 (12+3 opt)       | Reader 3 分割、optimize/ 追加 |
| lang/        | 74        | 21 (Zig) + 13 (clj) | prim 分割で可読性向上         |
| app/         | 7         | 8                   | repl/ サブディレクトリ化      |
| modules/     | 0 (!)     | 7                   | モジュールシステム新設        |
| **合計 Zig** | 120       | 64                  | **47% 削減**（責務集約）      |

---

## 3. Layer 0: runtime/ — 値・コレクション・GC・環境

### 3.1 value.zig — NaN Boxing

04_super_detail.md §1 の設計をそのまま採用。追加の監査結果:

**ヒープ型スロット割り当て（1:1 マッピング、CW のスロット共有を回避）:**

| Group (tag) | Sub 0    | Sub 1  | Sub 2   | Sub 3     | Sub 4     | Sub 5     | Sub 6       | Sub 7      |
|-------------|----------|--------|---------|-----------|-----------|-----------|-------------|------------|
| A (0xFFFA)  | string   | symbol | keyword | list      | vector    | array_map | hash_map    | hash_set   |
| B (0xFFFE)  | fn_val   | atom   | var_ref | regex     | protocol  | multi_fn  | protocol_fn | delay      |
| C (0xFFF8)  | lazy_seq | cons   | reduced | ex_info   | ns        | agent     | ref         | volatile   |
| D (0xFFFF)  | t_vector | t_map  | t_set   | chunk_buf | chunked_c | wasm_mod  | wasm_fn     | class_inst |

**CW との差分:**
- array_map と hash_map を別スロット（CW は map スロットを共有 + discriminant）
- protocol_fn を独立スロット（CW は fn_val 内に混在）
- 1:1 マッピングにより型チェックが単純な bit 比較のみ

**HeapHeader:**

```zig
pub const HeapHeader = extern struct {
    tag: HeapTag,       // u8: 型識別
    flags: packed struct {
        marked: bool,   // GC マークビット（CW の HashMap 方式を改善）
        frozen: bool,   // Arena 凍結フラグ
        _pad: u6,
    },
};
```

### 3.2 collection/list.zig — PersistentList + ArrayMap

最小のコレクション実装。Phase 1 で cons cell のみ:

```zig
pub const Cons = struct {
    first: Value,
    rest: Value,   // nil or another Cons
    meta: ?*Value,
    count: u32,
};
```

Phase 5 で ArrayMap (≤8 エントリ) を追加。Vector/HashMap は別ファイル。

### 3.3 collection/hamt.zig + collection/vector.zig — 永続データ構造

**Phase 5 で実装**。04_super_detail.md §4 の設計に基づく。

- `collection/hamt.zig`: BitmapNode + CollisionNode、`@popCount` 使用
- `collection/vector.zig`: 32-way trie + tail 最適化
- ArrayMap → HashMap 自動昇格（閾値 8）

### 3.4 gc/ サブディレクトリ — GC サブシステム

**分離の理由 (A4)**: CW の gc.zig は 1,948 LOC の単一ファイル。
ClojureWasm (新) では gc/ ディレクトリに 3 ファイルで分離:

| ファイル          | 責務                           | Phase |
|-------------------|--------------------------------|-------|
| gc/arena.zig      | GC インターフェース + Arena GC | 1     |
| gc/mark_sweep.zig | Mark-Sweep + Free Pool         | 5 末  |
| gc/roots.zig      | RootSet 定義 + 型別マーク走査  | 5 末  |

**Mark-Sweep 導入タイミングの修正:**

旧計画では Phase 6 (LazySeq) で初めて GC が必要とされていたが、
Phase 5 (HAMT) の transient コレクションでも一時オブジェクトが大量発生する。
**Mark-Sweep を Phase 5 の末尾で導入**。

**Day 1 から組み込む要素 (D11, D100):**
- `gc_mutex: std.Thread.Mutex = .{}`
- `suppress_count: u32` — マクロ展開中の GC 抑制
- HeapHeader にマークビット直接格納
- `--gc-stress` フラグ（毎アロケーションで collect 強制）

**CW D100 で発見されたルート追跡漏れへの対策:**

1. マクロ展開中の sweep → suppress_count で抑制
2. valueToForm の文字列ポインタ → node_arena にコピー
3. refer() のシンボルポインタ → infra_alloc にコピー
4. Protocol キャッシュ stale → generation カウンタ

### 3.5 env.zig — 名前空間と Var

```zig
pub const Namespace = struct {
    name: []const u8,
    mappings: VarMap,    // この NS で定義された vars
    refers: VarMap,      // 他 NS からインポートした vars
    aliases: NsAliasMap, // NS エイリアス
};

pub const Var = struct {
    ns: *Namespace,
    name: []const u8,
    root: Value,
    meta: ?*Value,
    flags: packed struct {
        dynamic: bool,
        macro_: bool,
        private: bool,
        _pad: u5,
    },
};
```

動的束縛: `pub threadlocal var current_frame: ?*BindingFrame = null;`

### 3.6 dispatch.zig — vtable パターン

```zig
// Layer 0 で定義、Layer 1/2 が起動時にセット
pub var callFn: *const fn(Value, []const Value) anyerror!Value = undefined;
pub var valueTypeKey: *const fn(Value) []const u8 = undefined;
pub var expandMacro: *const fn(Value, []const Value) anyerror!Value = undefined;

// スレッドローカル状態
pub threadlocal var current_env: ?*Env = null;
pub threadlocal var last_thrown_exception: ?Value = null;
```

### 3.7 error.zig — エラーインフラ (D12)

**Phase 1 から完全実装。CW の 1,252 箇所手書き setErrorFmt を排除。**

```zig
pub const SourceLocation = struct {
    file: []const u8,   // "REPL" or "src/my_app/core.clj"
    line: u32,          // 1-based
    column: u16,        // 0-based
};

pub const BuiltinFn = *const fn(
    args: []const Value,
    loc: SourceLocation,
) anyerror!Value;

// 型アサーションヘルパー
pub fn expectNumber(val: Value, loc: SourceLocation) !f64 { ... }
pub fn expectString(val: Value, loc: SourceLocation) ![]const u8 { ... }
pub fn checkArity(name: []const u8, args: []const Value, expected: usize, loc: SourceLocation) !void { ... }

// ソースコード周辺表示
pub fn showSourceContext(source: []const u8, loc: SourceLocation, buf: []u8) []const u8 { ... }

// ANSI 整形エラー (Layer 0 で実装、I/O 依存なし、テスト可能)
pub fn formatErrorAnsi(info: *const ErrorInfo, stack: []const StackFrame, buf: []u8, color: bool) []const u8 { ... }
```

### 3.8 keyword.zig — キーワードインターン

```zig
var intern_mutex: std.Thread.Mutex = .{};
var intern_table: std.StringHashMap(*Keyword) = undefined;

pub fn intern(ns: ?[]const u8, name: []const u8) *Keyword {
    intern_mutex.lock();
    defer intern_mutex.unlock();
    // ...
}
```

---

## 4. Layer 1: eval/ — Reader・Compiler・VM・TreeWalk

### 4.1 Reader 3 ファイル分離

CW の 3 ファイル分離（2,881 行合計）が成功しているため、同じ構造を採用:

| ファイル      | 責務                         | LOC 目標 |
|---------------|------------------------------|----------|
| tokenizer.zig | テキスト → トークン列        | ~500     |
| reader.zig    | トークン → Form ツリー       | ~1,000   |
| form.zig      | Form 構造体 + SourceLocation | ~200     |

**Reader の段階的スコープ** (04_super_detail.md §5.11):

- Phase 1: nil, bool, int, float, string, keyword, symbol, list, vector, map, comment, quote, `##`, `#_`, `#!`
- Phase 2: syntax-quote, unquote, fn literal, char literal
- Phase 3: metadata, var-quote, reader conditional, BigInt/BigDecimal, Ratio
- Phase 5: set, deref, regex, namespaced map, hex/octal/radix
- Phase 7: tagged literal

### 4.2 Analyzer + Node

Form → Node AST 変換。特殊形式を tagged union で型安全にディスパッチ:

```zig
// node.zig
pub const Node = union(enum) {
    // 特殊形式 (Phase 1-2)
    def_node: DefNode,
    if_node: IfNode,
    do_node: DoNode,
    quote_node: QuoteNode,
    fn_node: FnNode,
    let_node: LetNode,
    loop_node: LoopNode,
    recur_node: RecurNode,
    // 式
    call_node: CallNode,
    local_ref: LocalRef,
    var_ref: VarRef,
    constant: ConstantNode,
    // Phase 3+
    var_node: VarNode,
    set_node: SetNode,
    throw_node: ThrowNode,
    try_node: TryNode,
    // Phase 5+
    letfn_node: LetFnNode,
    case_node: CaseNode,
    lazy_seq_node: LazySeqNode,
    // Phase 9+
    reify_node: ReifyNode,
    defprotocol_node: DefProtocolNode,
    extend_type_node: ExtendTypeNode,
};
```

**Analyzer の役割:**
1. シンボル解決（ローカル vs var vs 特殊形式）
2. マクロ展開
3. スコープ追跡（ローカル変数のインデックス化）
4. 特殊形式の構文検証

### 4.3 Compiler + opcode.zig

**opcode.zig**: opcode enum を別ファイルに分離。

Phase 1 の最小 opcode セット（39 個）:
```
Constants:  const_load, nil, true_val, false_val
Stack:      pop, dup, pop_under
Locals:     local_load, local_store
Control:    jump, jump_if_false, jump_back
Functions:  call, ret, closure
Loop:       recur
Vars:       var_load, def, set_bang
Collections: list_new, vec_new, map_new, set_new
Arithmetic: add, sub, mul, div, mod, rem, eq, neq, lt, le, gt, ge
Exception:  try_begin, pop_handler, throw_ex, exception_type_check
```

**命令フォーマット（CW 3 バイトから 4 バイトに変更）:**

```zig
pub const Instruction = packed struct {
    op: OpCode,       // u8
    flags: u8 = 0,    // def の macro/dynamic/private フラグ等
    operand: u16 = 0, // 定数インデックス、スロット、ジャンプ先
};
// 理由: 4 バイトアライメントでキャッシュフレンドリー、
//       flags フィールドで def バリアント統合（opcode 節約）
```

### 4.4 VM (vm.zig)

スタックベース VM。CW の vm.zig (3,152 LOC) を参考に ~1,500 LOC 目標。

### 4.5 TreeWalk (tree_walk.zig)

**Phase 2 で実装**。Bootstrap Stage 0 に必要な最小セット:
- def, if, do, fn*, let*, quote, loop*, recur

**TreeWalk にも完全なエラートレース (D12):**
```zig
fn evalForm(self: *TreeWalk, form: Form) !Value {
    error.pushFrame(form.loc);
    defer error.popFrame();
    // ...
}
```

### 4.6 eval/optimize/ — 最適化の集約 (A3)

**全ての最適化コードを独立ファイルに分離。compiler.zig に混ぜない。**

| ファイル              | 内容                       | Phase |
|-----------------------|----------------------------|-------|
| peephole.zig          | ピープホール最適化         | 13    |
| super_instruction.zig | スーパーインストラクション | 17    |
| jit_arm64.zig         | ARM64 JIT コンパイラ       | 20    |
| jit_x86_64.zig        | x86_64 JIT コンパイラ      | 20+   |

コンパイラは最適化パイプラインを呼び出す:
```zig
// compiler.zig
pub fn compile(form: Form) !Bytecode {
    var code = self.emitBasic(form);
    if (comptime optimize_level > 0) {
        code = @import("optimize/peephole.zig").optimize(code);
    }
    return code;
}
```

### 4.7 Evaluator (backend/evaluator.zig)

Phase 8 で実装。VM と TreeWalk の結果を比較:

```zig
pub fn compare(form: Form) !Value {
    const vm_result = try vm.run(form);
    const tw_result = try tree_walk.run(form);
    if (!eql(vm_result, tw_result)) @panic("VM/TreeWalk mismatch");
    return vm_result;
}
```

---

## 5. Layer 2: lang/ — Primitives・Bootstrap・Interop

### 5.1 プリミティブ分割戦略 (A6)

CW の collections.zig (6,268 LOC) の問題を回避するため、
プリミティブを **primitive/ ディレクトリに 15 ファイルで分割**:

| ファイル               | 内容                                              | 関数数 | Phase |
|------------------------|---------------------------------------------------|--------|-------|
| primitive/core.zig     | apply, type, identical?                           | ~10    | 2     |
| primitive/seq.zig      | first, rest, next, cons, seq, empty?              | ~15    | 1     |
| primitive/coll.zig     | assoc, dissoc, get, conj, count, nth, into        | ~20    | 1     |
| primitive/math.zig     | +, -, `*`, /, mod, rem, inc, dec, compare         | ~15    | 1     |
| primitive/string.zig   | str, subs, string?, char, name, namespace         | ~10    | 1     |
| primitive/pred.zig     | nil?, number?, keyword?, fn?, coll?, seq?         | ~20    | 1     |
| primitive/io.zig       | println, pr, prn, print, newline, flush           | ~10    | 2     |
| primitive/meta.zig     | meta, with-meta, vary-meta, alter-meta!           | ~5     | 3     |
| primitive/ns.zig       | in-ns, require, refer, alias, all-ns              | ~10    | 4     |
| primitive/atom.zig     | atom, deref, swap!, reset!, compare-and-set!      | ~8     | 5     |
| primitive/protocol.zig | defprotocol, extend-type, satisfies?              | ~10    | 9     |
| primitive/error.zig    | ex-info, ex-message, ex-data, ex-cause            | ~5     | 3     |
| primitive/regex.zig    | re-find, re-matches, re-seq, re-pattern           | ~5     | 10    |
| primitive/lazy.zig     | lazy-seq thunk creation, realized?                | ~3     | 6     |
| primitive.zig          | 登録エントリポイント(全 `primitive/*.zig` を統合) | —      | 1     |

### 5.2 primitive.zig — 登録エントリポイント

```zig
pub fn registerAll(env: *Env) void {
    const rt = env.findOrCreateNs("rt");
    const seq = @import("primitive/seq.zig");
    const coll = @import("primitive/coll.zig");
    const math = @import("primitive/math.zig");
    const string = @import("primitive/string.zig");
    const pred = @import("primitive/pred.zig");
    seq.register(rt);
    coll.register(rt);
    math.register(rt);
    string.register(rt);
    pred.register(rt);
    // Phase 2+ は comptime で段階的に有効化
}
```

### 5.3 core.clj — upstream 適応ルール

```
置換パターン A: RT.xxx()     → rt/xxx       (直接対応)
置換パターン B: .method(obj) → rt/method    (インスタンスメソッド)
置換パターン C: Class/field  → rt/field     (静的フィールド)
```

upstream で変更が必要な行: **~1.6% のみ** (8,229 行中 ~130 行)。

### 5.4 bootstrap.zig — 7 段階ブートストラップ

```
Stage 0: list, cons, first, rest, seq, nil?, = (pre-defn 最小 20 rt/ 関数)
Stage 1: second, ffirst, last, butlast, sigs
Stage 2: syntax-quote 展開に必要な関数 (concat, apply, list*)
Stage 3: defn (TURNING POINT — upstream line 285)
Stage 4: defn を使った core.clj の残り (~570 定義)
Stage 5: clojure.string, clojure.set, clojure.walk
Stage 6: clojure.test, clojure.edn, clojure.pprint
```

### 5.5 macro_transforms.zig — Zig レベルマクロ

core.clj の defmacro では実装できない変換:

| マクロ     | 理由                                      | Phase |
|------------|-------------------------------------------|-------|
| `defmacro` | .setMacro() が Java メソッド → 特殊形式化 | 2     |
| `ns`       | ブートストラップ前に必要                  | 4     |

---

## 6. Layer 3: app/ — CLI・REPL・nREPL・Builder

### 6.1 cli.zig — 統一 CLI (P8)

**cljw バイナリ一つで全てをカバー:**

```
cljw                              REPL 起動
cljw file.clj                     ファイル実行
cljw -e '(+ 1 2)'                 インライン評価
cljw -i a.clj -e '...' b.clj      組み合わせ実行（順序、状態共有）
cljw -m my.app                     -main 実行
cljw -r                           ロード後 REPL
cljw --nrepl-server --port=7888    nREPL サーバー起動
cljw js src/ -o dist/              CLJS → JS コンパイル
cljw build -o myapp src/main.clj   シングルバイナリ生成
cljw -P                           deps.edn 依存解決
cljw --version                     バージョン
cljw -h                           ヘルプ
```

### 6.2 app/repl/ — REPL + nREPL

**CW は nREPL を完全実装（14 オペレーション、bencode、TCP）。
ClojureWasm (新) でも同等機能を提供。**

**repl.zig:**
- プロンプトに現在の NS 表示 (`user=>`)
- 複数行入力（括弧バランス追跡）
- `*1`, `*2`, `*3`, `*e` 変数
- ANSI カラー出力（isatty 判定）

**nrepl.zig (Phase 14):**
- TCP ソケットサーバー (`127.0.0.1:<port>`)
- `.nrepl-port` ファイル生成（CIDER/Calva/Conjure 自動検出）
- クライアントごとにスレッド生成
- サポートする nREPL オペレーション（14 個）:

| Op          | 機能             | 優先度 |
|-------------|------------------|--------|
| clone       | セッション複製   | 必須   |
| close       | セッション終了   | 必須   |
| describe    | サーバー情報     | 必須   |
| eval        | コード評価       | 必須   |
| load-file   | ファイルロード   | 必須   |
| completions | 補完候補         | 高     |
| info        | シンボル情報     | 高     |
| lookup      | ドキュメント検索 | 高     |
| eldoc       | 関数シグネチャ   | 高     |
| ls-sessions | セッション一覧   | 中     |
| ns-list     | 名前空間一覧     | 中     |
| stacktrace  | スタックトレース | 中     |
| stdin       | 標準入力転送     | 低     |
| interrupt   | 評価中断         | 低     |

**line_editor.zig:**
- ANSI ターミナル制御、履歴、Emacs キーバインド、Tab 補完

**bencode.zig:**
- nREPL ワイヤプロトコル用エンコーダ/デコーダ

### 6.3 builder.zig — シングルバイナリ (D9)

```
[cljw binary] + [serialized payload] + [u64 size] + "CWNB"
```

### 6.4 deps.zig — deps.edn 解決 (Phase 14)

`:paths`, `:deps` (`:local/root`), `:aliases` の基本対応。
Maven/Git 依存は Phase 14+ で段階的に追加。

---

## 7. modules/ — モジュールシステム

### 7.1 ModuleDef インターフェース

```zig
pub const ModuleDef = struct {
    name: []const u8,
    ns_name: []const u8,
    builtins: []const BuiltinEntry,
    clj_sources: ?[]const EmbeddedSource = null,
    init: ?*const fn(*Env) void = null,
};
```

### 7.2 comptime フラグ (D6)

```bash
zig build                       # math のみ (デフォルト)
zig build -Dc-ffi=true          # math + C FFI
zig build -Dwasm=true           # math + Wasm
zig build -Dmath=false           # 最小バイナリ
```

### 7.3 モジュール追加の手順

1. `modules/foo/module.zig` に ModuleDef を定義
2. `modules/foo/builtins.zig` に関数を実装
3. `build.zig` に comptime フラグを追加
4. **src/ 内のコードは一切変更しない (A2)**

---

## 8. Phase 実装順序（監査済み）

### 8.1 Phase 再編成のポイント

| 変更点                               | 理由                                    |
|--------------------------------------|-----------------------------------------|
| Reader を Phase 1 で 3 ファイル分割  | CW で実証済み。後から分割は困難         |
| Analyzer + Node を Phase 2 に前倒し  | 特殊形式の型安全なディスパッチに必要    |
| Mark-Sweep GC を Phase 5 末に移動    | HAMT transient の一時オブジェクトに必要 |
| nREPL を Phase 14 に追加             | CW が持つ機能。エディタ連携に必須       |
| optimize/ を Phase 13, 17, 20 に分散 | 各最適化を独立 Phase で実装             |
| deps.zig を Phase 14 に含める        | CLI リリースと同時に deps.edn 基本対応  |

### 8.2 完全 Phase リスト

```
Phase  1: Value + Reader (3 files) + Error infra + Arena GC
Phase  2: TreeWalk + Analyzer/Node + Bootstrap Stage 0 + defmacro
Phase  3: defn (Bootstrap Stage 1-3) + ExceptionInfo + Metadata
Phase  4: VM + Compiler + opcode.zig
Phase  5: Collections (HAMT, Vector, ArrayMap) + Mark-Sweep GC 導入
Phase  6: LazySeq + concat + core.clj higher-order 基盤
Phase  7: map/filter/reduce/range/iterate + Transducers 基盤
Phase  8: Evaluator.compare() + デュアルバックエンド検証
Phase  9: Protocols + Multimethods + extend-type + reify
Phase 10: Namespaces + require + ns マクロ + clojure.string/set/walk
Phase 11: clojure.test + テストフレームワーク
Phase 12: Bytecode Cache (cache_gen + serialize + @embedFile)
Phase 13: VM Optimization Phase 1 (peephole.zig)
Phase 14: CLI + REPL + nREPL + deps.edn + Single Binary + v0.1.0
Phase 15: Concurrency (future, promise, pmap, STM, agent)
Phase 16: ClojureScript → JS Emit (analyzer/emitter/resolver in .clj)
Phase 17: Optimization Phase 2 (super_instruction.zig)
Phase 18: Module system + math + C FFI
Phase 19: module: Wasm FFI (zwasm)
Phase 20: module: JIT ARM64 + x86_64 (jit_arm64.zig, jit_x86_64.zig)
```

### 8.3 Phase 1 詳細（最重要）

**成果物**: Value 型 + Reader + Error インフラ + Arena GC

**ファイル実装順序:**

```
 1. src/runtime/value.zig              NaN Boxing, inline 型チェック
 2. src/runtime/error.zig              SourceLocation, BuiltinFn signature, helpers
 3. src/runtime/gc/arena.zig           Arena GC (gc_mutex 含む、未ロック)
 4. src/runtime/collection/list.zig    PersistentList (cons cell)
 5. src/runtime/hash.zig               Murmur3 (keyword/symbol 用)
 6. src/runtime/keyword.zig            Keyword intern (mutex 付き)
 7. src/eval/form.zig                  Form 構造体 + SourceLocation
 8. src/eval/tokenizer.zig             字句解析
 9. src/eval/reader.zig                構文解析 (Phase 1 スコープ)
10. src/main.zig                       -e のみの最小 CLI
```

### 8.4 Phase 2 詳細

**成果物**: TreeWalk 評価器 + Analyzer + Bootstrap Stage 0

```
 1. src/runtime/env.zig           Namespace, Var, rt NS
 2. src/runtime/dispatch.zig      vtable + threadlocal state
 3. src/eval/node.zig                  Node tagged union
 4. src/eval/analyzer.zig              Form → Node 変換
 5. src/eval/backend/tree_walk.zig     AST 直接評価
 6. src/lang/primitive/seq.zig     first, rest, cons, seq, next
 7. src/lang/primitive/coll.zig    assoc, get, count
 8. src/lang/primitive/math.zig    +, -, *, /, compare
 9. src/lang/primitive/string.zig  str, string?
10. src/lang/primitive/pred.zig    nil?, number?, keyword?, fn?
11. src/lang/primitive/io.zig      println, pr, prn
12. src/lang/primitive/core.zig    apply, type
13. src/lang/primitive.zig         登録エントリポイント
14. src/lang/macro_transforms.zig defmacro Zig レベル変換
15. src/lang/bootstrap.zig        Stage 0 実行
16. src/lang/clj/clojure/core.clj Stage 0 (~50 行)
```

---

## 9. ユーザー体験設計

### 9.1 cljw コマンドの使用感

```bash
$ cljw                          # REPL が起動。すぐに使える。
user=> (+ 1 2)
3
user=> (require '[clojure.string :as str])
nil
user=> (str/join ", " ["a" "b" "c"])
"a, b, c"
```

### 9.2 エラー体験 (P6)

```
Type error: Cannot add integer and string
  at user/f (REPL:1:17)

   1 | (defn f [x] (+ x "hello")) (f 42)
                       ^^^^^^^^^
                       Expected number, got string

  Stack trace:
    user/f    (REPL:1:17)
```

### 9.3 nREPL 体験

CIDER/Calva/Conjure で:
- `cljw --nrepl-server` → `.nrepl-port` 生成 → エディタ自動接続
- `C-c C-e` (eval) → バッファ内で結果表示
- `M-.` (info) → ソース定義にジャンプ
- Tab → 補完候補

---

## 10. 最適化戦略の集約

### 10.1 配置原則 (A3)

**全ての最適化コードは src/eval/optimize/ に集約。
コア実装（compiler.zig, vm.zig）に最適化ロジックを混ぜない。**

| ファイル              | 内容                       | Phase | CW 実測効果  |
|-----------------------|----------------------------|-------|--------------|
| peephole.zig          | ピープホール最適化         | 13    | —            |
| super_instruction.zig | スーパーインストラクション | 17    | VM +15-20%   |
| jit_arm64.zig         | ARM64 JIT                  | 20    | ループ 10.3x |
| jit_x86_64.zig        | x86_64 JIT                 | 20+   | —            |

### 10.2 GC 最適化

gc/mark_sweep.zig に集約:
- Free Pool: sweep 済みメモリの O(1) 再利用 (CW 実測: GC 7x 高速化)
- 閾値適応: collect 後に半分以上残存 → 閾値倍増
- ストレスモード: `--gc-stress` で毎アロケーション collect

---

## 11. 品質管理とテスト戦略

### 11.1 TDD サイクル (t-wada スタイル)

1. **Red**: 失敗するテストを 1 つだけ書く
2. **Green**: テストを通す最小コードを書く
3. **Refactor**: テストが緑のまま改善

### 11.2 コミットゲートチェックリスト

1. `zig build test` + `zig build -Doptimize=ReleaseSafe` — 全テスト PASS
2. `bash scripts/zone_check.sh --gate` — ゾーン違反 0
3. バイナリサイズ ≤ 5.0MB, 起動 ≤ 10ms, RSS ≤ 15MB
4. vars.yaml, memo.md 更新

### 11.3 テスト構造 (A5)

```
test/
├── runtime/        Layer 0 ユニットテスト
├── eval/           Layer 1 ユニットテスト
├── lang/           Layer 2 統合テスト
├── app/            Layer 3 E2E テスト
├── clj/            Clojure レベルテスト
└── e2e/            エンドツーエンドシナリオテスト
```

---

## 12. CW 教訓の設計反映チェックリスト

| #   | CW 教訓                          | 反映セクション | 状態 |
|-----|----------------------------------|----------------|------|
| L1  | レイヤー依存方向の厳守           | §2, §3.6       | ✓    |
| L2  | 並行性は後付けできない           | §3.4, §3.5     | ✓    |
| L3  | エラー基盤は後付けできない       | §3.7           | ✓    |
| L4  | core.clj 捨てて車輪の再発明      | §5.3           | ✓    |
| L5  | テスト駆動でないと品質低下       | §11.1          | ✓    |
| L6  | i48 オーバーフローの暗黙変換     | §3.1           | ✓    |
| L7  | GC ルート追跡漏れ                | §3.4           | ✓    |
| L8  | Protocol キャッシュに generation | §5.1           | ✓    |
| L9  | ホットパスの一時アロケーション   | §10.2          | ✓    |
| L10 | バイトコードキャッシュ           | §8.2 Phase 12  | ✓    |
| L11 | 「都度対応」の蓄積は破綻         | §1.1 P4        | ✓    |
| L12 | 拡張は modules/ に閉じる         | §7             | ✓    |
| L13 | ファイル構成は最初に決める       | §2             | ✓    |
| L14 | デュアルバックエンドで品質保証   | §4.7           | ✓    |
| L15 | 非機能要件は基準値で管理         | §11.2          | ✓    |
| NEW | builtins 6K LOC モノリス回避     | §5.1           | ✓    |
| NEW | nREPL サーバーの実装             | §6.2           | ✓    |
| NEW | Reader 3 ファイル分離            | §4.1           | ✓    |
| NEW | 最適化コードの明確な分離         | §4.6, §10      | ✓    |
| NEW | GC サブシステムのファイル分離    | §3.4           | ✓    |
| NEW | Mark-Sweep GC の導入タイミング   | §8.2 Phase 5末 | ✓    |

---

> 本文書は ClojureWasm フルスクラッチ再実装の最終設計基盤。Phase 1 着手時に本文書を参照し、
> ディレクトリ構造を確定すること。以降の Phase では本文書の構造を維持し、
> **ファイル追加ではなく内容実装** に集中する。
