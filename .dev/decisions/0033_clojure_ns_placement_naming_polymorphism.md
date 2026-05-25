# 0033 — Clojure-ns var placement decision rule + `defn-`/`-name` naming + hybrid polymorphism + transducer 先取り + 10-cycle transient migration plan

**Status**: Accepted (Devil's-advocate fork landed 2026-05-25)
**Date**: 2026-05-25
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: phase-6-late, structure, clojure-source, self-hosting,
naming, transducer, polymorphism, F-009

## Context

cw v1 が Phase 6.9-6.11 で着地した 32 vars (`clojure.string` 22 +
`clojure.set` 7 + `clojure.walk` 3) は全て **Zig 直書き**、 対応する
`.clj` ファイルは `(in-ns ...)` ヘッダーのみで defn 0 個。 これは
ADR-0032 (multi-file bootstrap loader) が用意した Layer 3 `.clj` 路線
が未活用な状態を意味する。

問題:

- (P-1) cw v0 で繰り返した「全部 Zig」 → user composition vacuum (= 「ユーザーが `(reduce conj #{} ...)` 書けない」)、 自己ホスティング時 1000+ 行翻訳作業、 JVM upstream diff visibility 喪失
- (P-2) 「愚直に JVM `.clj` port」 = Java InterOp で詰む、 class hierarchy 全部要求、 「core 完成まで何も書けない」 で Zig に逃げる failure mode
- (P-3) Phase 7 (protocol + transducer fused)、 Phase 10 (Tier A polish official)、 Phase 12 (bytecode cache)、 Phase 14 (cljw build v0.1.0)、 Phase 16 (zwasm + ClojureScript)、 Phase 17 (JIT) の全 Phase で placement が stable な投資である必要

cw v0 真の構造 (`embedded_sources.zig` 6206 行 + `__zig-` prefix 規約)
は (P-1) を回避するための ad-hoc な「Pattern A `.clj` defn + Pattern B
Zig leaf」 折衷案だった (cw v0 evidence)。 cw v1 では ADR-0032 が clean
な multi-file loader を用意済、 ただし中身が空。 本 ADR がこれを埋める
formal placement + naming + 段階移行を確定する。

詳細な discussion は `private/notes/clj_vs_zig_split_proposal_v5.md`
(1593 行、 self-contained) を SSOT として参照。

## Decision

### D1: 3-layer architecture (v5 §2.1)

```
Layer 3: Clojure source     src/lang/clj/clojure/*.clj
                            (Pattern A defn + Pattern B2 1-line shim 同居)
            ↓ calls
Layer 2: Zig primitive      src/lang/primitive/
                            (2a) core glue primitives ← Pattern A が依存
                            (2b) `-name` leaf (B2) / 直 intern (B1)
            ↓ calls
Layer 1: runtime/           pure Zig / OS / std binding (F-009 neutral)
```

### D2: Placement decision rule (B-Q1 → B-Q4)

```
B-Q1: impl は他の user-callable Clojure var の合成として書けるか?
  YES → Pattern A (.clj defn)、 ingredient が Layer 2 既登録前提
  NO  → B-Q2
B-Q2: impl は neutral impl 1 個の薄いラッパーか?
  YES → Tier A surface (clojure.X/v) → Pattern B2 (-name leaf + 1-line shim)
        OS leaf / Java InterOp 純置換 → Pattern B1 (Zig 直 intern)
  NO  → B-Q3
B-Q3: impl は polymorphic dispatch / core glue 自身か?
  YES → Pattern B1 (Layer 2 2a)
  NO  → B-Q4 (ADR レベル判断、 Devil's-advocate fork)
```

完全 flowchart: v5 Appendix E。

### D3: 2 Patterns + sub-patterns

| Pattern | 配置                                         | 適用ケース                              |
|---------|----------------------------------------------|-----------------------------------------|
| A       | Layer 3 `.clj` (`defn`)                      | composition、 公開 var                  |
| B1      | Layer 2 `.zig` 直 intern (`.clj` 不在)       | OS leaf、 JVM 対応 diff 不要、 公開 var |
| B2      | Layer 2 `-name` intern + Layer 3 1-line shim | Tier A surface、 JVM diff 維持          |
| C-thin  | `.clj` で 1-2 条件分岐 + leaf 呼出           | `blank?` 等                             |
| C-zig   | Layer 2 全実装 (B1 同形)                     | multi-arity 複雑 / hot path             |

「C-fat」 「transient」 等の中間 label は廃止 ── transitional 状態は
`placement.yaml` の `status: transient_zig` field で表現。

### D4: Naming convention `defn-` + `-name` + metadata

- 公開 var: `clojure.X/upper-case` (通常 `defn`、 prefix なし)
- 内部 leaf: `clojure.X/-upper-case` (single-dash prefix、 `defn-` =
  `^:private` 同等、 `^:zig-leaf true` metadata 付き Zig intern)
- **両者同一 ns に共存** (sub-ns `impl/` 案は採用しない理由 = 完成後の
  取り残し risk + 分散コスト、 v5 §App E + 棄却根拠)
- JVM Clojure 慣習 `defn-` に完全準拠
- **`__zig-` 等の別 namespace marker は採用しない** (= 機械生成感 +
  Clojure 慣習からの drift)
- `private` だけで全ケース賄える: 公開 surface (`defn`) / 公開 Zig 直
  intern / 内部 B2 leaf (`-name` + `defn-`) / 内部 Zig leaf
  (`^:private :zig-leaf` metadata) のいずれも prefix + metadata で
  区別可能 (v5 §3.1.1 確認表)

### D5: Hybrid polymorphism (Zig 強さ + Protocol extension)

Phase 6.16.a-1/a-2 で着地する polymorphic primitives (count / seq /
conj / reduce 等) は:

- **Phase 6.16.a 段階**: Zig Tag switch hardcode (NaN-box Tag 0..15 を
  comptime/runtime で switch、 inline 最適化 + 型推論利用)
- **Phase 7 段階** (D-069 row): Protocol extension point を **追加 path**
  として開く (置換ではない)。 fast-path = Tag switch 維持、 slow-path =
  `extend-protocol` されたものだけ通る。 user の `(extend-type MyColl
  IPersistentColl ...)` を許す。

実装 shape (推奨):

```zig
pub fn count(rt: *Runtime, coll: Value) !i64 {
    switch (coll.tag()) {
        .vector, .list, .cons, .lazy_seq,
        .array_map, .hash_map, .hash_set, .string_seq => {
            return countBuiltin(rt, coll);  // fast path
        },
        .protocol_extended => {
            return rt.protocol.dispatch(.count, coll);  // slow path
        },
        else => return error.type_error,
    }
}
```

**申し送り**: 「protocol 着地で全 dispatch を polymorphic 化」 ではなく
「fast-path 維持 + extension point を 追加」。 各 Phase のベスト形を
尽くす方針 (= 妥協ではない)。 D-069 で Phase 7 entry に formal
landing。

### D6: Core glue primitive set + var-level dependency order

Phase 6.16.a-1/a-2/a-3 で着地する確定 set + 順序:

```
6.16.a-1 fundamentals (1 cycle):
  count → seq → first → rest → cons → empty

6.16.a-2 collection ops (1 cycle):
  conj → disj → contains? → get → nth → assoc → dissoc → keys → vals

6.16.a-3 higher-order + transducer (2-3 cycles):
  apply → reduce (素朴版) → into → map → filter → take → drop → keep
  → remove → every? → some → some?
  + Layer 3 .clj defn: partial / comp / complement / constantly / juxt
```

順序は本 ADR で確定、 cycle 内で実装中に判明する依存は recall trigger
として permit (ADR amendment で記録)。 詳細 cycle deliverable は ROADMAP
§9.8 6.16.a-X rows。

### D6a: Transducer 先取り spec

Phase 6.16.a-3 で `map` / `filter` / `take` / `drop` / `keep` / `remove`
を着地する際:

- **multi-arity 完全実装**: 1-arg arity (transducer return) + multi-arg
  arity (eager) を同時着地
- **rf protocol を Layer 2 で正式登録**: `(rf)` (init) / `(rf result)`
  (completion) / `(rf result input)` (step)
- **`into` も transducer-aware**: `(into [] xform coll)` 形

Phase 7 で着地する追加 (transduce / eduction / sequence transducer-aware
/ IReducingFn formal definition / partition-by 等 transducer-only HOF)
は **既存 defn 書き換え不要**。

### D7: 10 cycle 段階移行計画

```
6.16.a-0: env.intern API metadata 拡張 (small prerequisite)
6.16.a-1: core glue fundamentals (6 vars) + Tier 0 metadata size 実測
6.16.a-2: core glue collection ops (9 vars)
6.16.a-3: core glue higher-order + transducer (12 vars + 5 .clj HOF)
          [2-3 cycles range]
6.16.b:   clojure.set 12 vars .clj 化 (Group A+B+C 一括、 D-061 解消)
6.16.c:   clojure.walk 10 vars 着地 (8 A + 1 B2 leaf + 1 declare-only
          macroexpand-all、 Phase 7 で実装解除)
6.16.d:   clojure.string Pattern B2 14 vars shim 化
6.16.e:   clojure.string Pattern A + 混合 8 vars .clj 化
          (D-062 cluster row 解消条件)
```

= 9-11 cycle 追加、 Phase 6 完了 3-4 month 後ろ倒し受容。 詳細は
ROADMAP §9.8 + v5 §9。

### D8: env.intern API metadata 拡張

`env.intern(ns, name, value)` を:

```zig
pub fn intern(
    self: *Env,
    ns: []const u8,
    name: []const u8,
    value: Value,
    metadata: ?MetadataMap,
) !*Var
```

`MetadataMap = { private: bool, zig_leaf: bool, unsupported: bool,
doc: ?[]const u8, arglists: ?[]const u8 }`。 analyzer special-case で
`^:private` 違反を compile-time `private_access_error` raise、
`^:unsupported` declare-only var の呼出時に `feature_not_supported`
raise。 D-065 implementation row、 Phase 6.16.a-0 cycle で先行着地。

### D9: Babashka 機械解析 script (placement.yaml 初期生成)

`scripts/analyze_clojure_upstream.bb` (Babashka script、 ADR-0033 起票
**前** に着地、 v5 §10 + §15.4):

- 入力: `~/Documents/OSS/clojure/src/clj/clojure/{string,set,walk,zip}.clj`
- 出力: `private/notes/upstream_var_analysis.edn` (per-var、 pattern
  suggestion 付き)
- `scripts/gen_placement_yaml.bb` がこれを入力に `placement.yaml`
  initial 版を生成、 手動補正で `recall_trigger` / `composition_deps`
  refinement、 ADR-0033 起票時に commit

事前測定済 (v5 §10.2): set/walk/zip は 100% pure Clojure、 string は
17% Java InterOp、 機械判定で十分。

### D10: JIT independence claim

cljw build の embed 方式 (bytecode embed 確定、 ADR-0034) と将来の cw
独自 JIT 導入は **完全に直交**。 cw v0 Phase 32 (source bundling) の
後の Phase 37.4 で ARM64 JIT PoC が問題なく着地 (arith_loop 10.3x
speedup) した evidence。

- **narrow JIT** (hot loop only、 cw v0 同形): bytecode のみ入力で完結、
  完全直交
- **broad JIT** (tracing / method JIT、 zwasm v1 同形): optimization 用
  に source-level metadata が必要、 ADR-0034 amendment で bytecode に
  optional source-metadata field 追加で対応 (ABI 維持しつつ拡張)

Phase 17 go/no-go どちらでも本 ADR placement は影響なし。

## Alternatives considered

Devil's-advocate fork (general-purpose subagent、 fresh context、
2026-05-25 issuance、 F-001/F-004/F-005/F-006/F-009 envelope 内)
output verbatim:

#### Alt 1: ad-hoc Zig-direct, no formal placement rule

現状維持寄りの最小変更案。32 vars を Zig 直書きのまま保持し、`.clj` 化は「気付いた人がやる」式に任せる。ADR-0033 は起票せず、ROADMAP §9.6 cycle table に「opportunistic な .clj 化」一行を足す程度に留める。

- **Better**: 着地コストゼロ。Phase 6.16 entry を Phase 7 fast-path 設計に直結できる (placement 議論で時間を取らない)。env.intern metadata 拡張 / analyzer private check / babashka script / 10 cycle 移行表という新規 surface area を全て回避できる。`zig build test` の構造変更も不要。
- **Breaks**: (i) Pattern A composition (例: `clojure.string/blank?` = `every? char-whitespace?`) を書く際に call boundary が Zig 側に閉じ、placement の SSOT が「source を読まないと分からない」状態が永続化する。(ii) cw v1 が Clojure 本流の「stdlib は .clj で書かれている」性質を再現できず、F-009 (feature-implementation neutrality) の "neutral impl 共有" 主張の説得力が下がる — 共有点が全部 Zig 関数になるため、Clojure-ns / Java-ns 双方から「同じ .clj source を呼んでいる」事実が成立しない。(iii) transducer の 1-arg arity と multi-arity を Zig 内で同時着地させる場合、rf protocol が Layer 2 に formal 登録されないまま hard-coded dispatch になり、Phase 7 protocol extension の merge コストが後ろ倒しになる。
- **F-NNN 関係**: F-009 と弱衝突 (violate ではなく weaken)。F-001/F-004/F-005/F-006 は影響なし。
- **F-NNN violation**: なし (envelope 内)。

#### Alt 2: ADR-0033 本提案 (3-layer + D1-D10)

3-layer architecture (runtime / lang/primitive / lang/clj)、Pattern A/B1/B2/C-thin/C-zig 分岐、`defn-` + `-name` + `^:private :zig-leaf` metadata、Hybrid polymorphism (Tag fast-path + Protocol extension)、core glue primitive set + var-level dependency order、transducer 先取り (Phase 6.16.a-3)、10 cycle 段階移行、env.intern metadata 拡張、babashka 機械解析、JIT independence claim。

- **Better**: placement の SSOT が `.clj` source + `placement.yaml` に二重化され、人間にも機械にも explicit。Pattern A composition が Clojure source として直接読め、JVM upstream との diff が `bb run lint-placement` で機械検出可能。transducer rf protocol を Phase 6.16.a-3 で formal 登録するため Phase 7 protocol 拡張の追加コストが小さい (= 既存 path を置換しない、追加 path として開く)。F-009 neutral impl 共有が source level で観測可能になる (Clojure-ns / Java-ns が同じ .clj を呼ぶ)。
- **Breaks**: (i) 10 cycle 移行中に Layer 2 thin wrapper と Layer 3 .clj source の責任境界が時々曖昧になる risk (特に Pattern B2 shim — Zig leaf + .clj shim の二段)。(ii) env.intern metadata 拡張 + analyzer private check は新規 surface area で、Phase 6.16.a-0 で 1 cycle 消費する。(iii) babashka 機械解析 script は JVM upstream の Clojure macro expansion に弱く、初期 placement.yaml 生成後の人間 review が事実上必須。(iv) `defn-` + `-name` の double-marker convention は読みやすさ減 (Clojure 慣習では `defn-` 単独で private を表す)。
- **F-NNN 関係**: F-009 を strengthen (neutral impl 共有が source level で成立)。F-004 Tag fast-path は Hybrid polymorphism D5 で温存。F-001/F-005/F-006 は影響なし。
- **F-NNN violation**: なし。

#### Alt 3: Protocol-only placement (Pattern A 全廃、全 var を polymorphic protocol method)

wildcard 案。32 vars 全てを ADR-0008 Protocol dispatch に統合し、Pattern A composition / Pattern B1/B2 分岐を廃止する。clojure.string/blank? も clojure.set/union も clojure.walk/walk も全て protocol method として実装、Tag fast-path は protocol の default impl が Tag switch を内包する形で表現。`.clj` source は protocol 宣言 + extend-type 群のみで構成され、placement.yaml は不要 (protocol registry が SSOT)。

- **Better**: placement の表現単位が一つ (protocol method) に統一され、Pattern A/B1/B2 の使い分け判断が消える。Phase 7 protocol extension が「新しい何かを開く」のではなく「既存 mechanism の追加 implementer」となり、conceptual coherence が高い。Java-ns / Clojure-ns / cljw-ns の cross-surface 主張 (F-009) が protocol という単一 abstraction に立脚し、説明が単純化する。
- **Breaks**: (i) NaN-box Tag 軸の direct dispatch (F-004 前提) と protocol dispatch の二重化を強要する — protocol method の default impl が Tag switch を内包する形になり、`count` / `first` 等 hot path に protocol resolution の overhead が乗る risk。Phase 7 narrow JIT で inlining し切れない場合 v0 baseline (arith_loop 10.3x) を下回る恐れ。(ii) transducer rf protocol が「protocol を protocol で実装する」入れ子になり、Layer 2 formal 登録の抽象度が一段上がる。(iii) Clojure 本流は protocol を「特定 abstraction の拡張点」として使い、stdlib 全体には用いない — JVM upstream との diff が大きくなり babashka 解析の前提が崩れる。
- **F-NNN 関係**: F-004 (Tag 軸 polymorphic dispatch) と緊張 — protocol dispatch を主、Tag switch を従に位置付けるため、F-004 の "Tag 軸前提" を弱める方向に働く。F-009 は strengthen。F-001/F-005/F-006 は影響なし。
- **F-NNN violation**: F-004 を strict reading すると violation 寄り (Tag dispatch を従属させるため)。loose reading (F-004 = NaN-box slot 数の確約のみ) なら envelope 内。本 alternative は loose reading 前提で envelope 内とする。strict reading を user が採る場合、本 alt は提案不可。

## Selection rationale

Alt 2 (本提案) を選択。 F-002 (finished-form wins) + F-009 (feature-
implementation neutrality を strengthen) の合致が決定的。 Alt 1 は F-009
weaken が致命的、 Alt 3 は F-004 strict reading 下で violation 寄り
(loose reading での envelope 内入りも hot path overhead risk が大きく
Phase 17 JIT go の場合の baseline 維持に不確実性を導入する)。

Alt 2 の Breaks (i)-(iv) は受容コストとして識別:
- (i) Pattern B2 shim 二段の責任境界曖昧化 → §15 placement.yaml SSOT で
  per-var leaf_loc / target_loc 明示することで risk 低減
- (ii) env.intern metadata 拡張の 1 cycle 消費 → Phase 6.16.a-0
  prerequisite として明示計画化、 サプライズなし
- (iii) babashka 解析の人間 review 必須 → ADR-0033 起票時の確認
  workflow に組込み済 (v5 §10)
- (iv) double-marker convention 可読性 → JVM Clojure `defn-` 慣習との
  互換性が user familiarity を担保、 Zig leaf marker (`^:zig-leaf`) は
  metadata なので surface text は標準 Clojure

## Consequences

- 32 vars が 9-11 cycle で migrate、 Phase 6 完了 3-4 month 後ろ倒し
- `placement.yaml` (新規) が Clojure-ns var placement の SSOT、
  `compat_tiers.yaml` (既存) は Java/cljw surface SSOT として共存
- Phase 7 protocol dispatch (ADR-0008) amendment が必須 (D-069)、 hybrid
  polymorphism pattern の formal landing
- Phase 11 conformance Layer 5 で Pattern A `.clj` が JVM upstream test
  と直接比較可能 (= conformance gap 検出が早期化)
- Phase 12 bytecode cache の主要対象 が Pattern A `.clj` defn、 build-
  time bytecode 化により runtime cost ゼロ
- Phase 14 cljw build single mode + `cljw render-error` 着地時に
  Pattern A `.clj` source が source map ref として有効活用
- Phase 16 ClojureScript transpiler の入力として Pattern A `.clj` 自然
  (D-068 spec ADR)、 ただし `-name` leaf は JS interop 置換必要
- Phase 17 JIT go/no-go どちらでも placement 無影響 (D10 claim)

## Affected files

- `placement.yaml` (新規、 initial scaffold 着地、 32 transitioning vars
  + 6 core glue entries)
- `compat_tiers.yaml` (schema 変更なし、 既存維持)
- `.dev/ROADMAP.md` §9.8 (rows 6.16.a-0 から 6.16.e 追加) +
  §9.14/§9.16/§9.18/§9.19 (deliverable 拡張)
- `.dev/debt.md` (D-062 cluster row + D-063 ADR-0035 起票 + D-065
  env.intern 拡張 + D-067 Wasm FFI spec + D-068 ClojureScript spec +
  D-069 Phase 7 hybrid polymorphism + D-058 subsumed flip)
- `.dev/handover.md` (Resume contract = ADR-0033 起票 → Phase 6.16.a-0
  へ)
- `CLAUDE.md` (Data sources に placement.yaml 追加)
- `private/notes/clj_vs_zig_split_proposal_v5.md` (v5 plan、 SSOT、
  1593 行、 self-contained)

Phase 6.16.a-0 cycle 以降の Affected files:

- `src/runtime/env.zig` (D-065 intern API metadata 拡張)
- `src/eval/analyzer/symbol.zig` (private violation check + unsupported
  marker)
- `src/lang/primitive/core/{core,sequence}.zig` (Phase 6.16.a-1 から
  fundamentals + collection ops)
- `src/lang/primitive/string.zig` / `set.zig` / `walk.zig` (Phase
  6.16.b/c/d/e で leaf rename + thin layer)
- `src/lang/clj/clojure/{string,set,walk}.clj` (Pattern A defn + Pattern
  B2 1-line shim)
- `scripts/check_placement_status.sh` (新規、 audit)
- `scripts/analyze_clojure_upstream.bb` (新規、 Babashka generator)
- `scripts/gen_placement_yaml.bb` (新規、 Babashka yaml generator)

## Revision history

- 2026-05-25 issued + accepted with Devil's-advocate fork
  (general-purpose subagent、 fresh context、 F-NNN envelope 内 3
  alternatives 取得 verbatim、 Alt 2 採択、 Alt 3 が F-004 strict
  reading で violation 寄りの旨を明示)。 v5 plan (1593 行、 self-
  contained) を SSOT として参照、 Phase 6.16.a-0 ~ .e の 10 cycle
  segment が ROADMAP §9.8 に landing。
