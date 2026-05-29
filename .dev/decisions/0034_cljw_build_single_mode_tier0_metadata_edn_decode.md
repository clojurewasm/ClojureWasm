# 0034 — cljw build single mode + Tier 0 metadata + structured EDN error event + post-mortem decode

**Status**: Accepted (Devil's-advocate fork landed 2026-05-25)
**Date**: 2026-05-25
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: phase-12-prep, build-pipeline, error-observability,
edge-target, F-001, F-006, F-009

## Context

cw v1 のメインターゲットは **エッジ実行** (Cloudflare Workers /
WASM Component / serverless cold-start)、 起動 < 5ms 要件。 `cljw
build` の output 形式 + error observability spec を本 ADR で確定する。
v5 §11-§14 + §19.2 SSOT。

cw v0 履歴 (Phase 28 source bundle → Phase 31 bytecode embed →
Phase 32 source bundle default + 32.2-32.3 bootstrap cache →
Phase 37.4 narrow JIT 着地) の 4 段階を再評価:

- Phase 32 で source bundle に統一したのは UI 整理 + multi-file
  require chain の bytecode dependency order 解決コスト回避が動機、
  **技術的判断ではない**
- Phase 31.5 短期間の bytecode embed user app 体験 + Phase 32.2-32.3
  bootstrap cache (12ms → 3-4ms 起動高速化) が user の 「bytecode 方が
  優れていた気がする」 直感の合成記憶根拠
- Phase 37.4 (ARM64 JIT PoC、 arith_loop 10.3x speedup) が source bundle
  形態の **後** に問題なく着地、 **JIT は embed 方式と完全直交** evidence

エッジ用途で source bundle (cold start +20-50ms) は許容不可。
**bytecode embed default** が技術的に正解。 ただし cw v0 が source
bundle を選んだ複雑さ (multi-file require chain の bytecode dependency
order) は本 ADR では ADR-0035 (require spec) に委譲し、 ADR-0034 は
build pipeline + error observability に focus する。

Phase 6.16.a-1 cycle (commit d35dc3b) terminus で Tier 0 metadata size
baseline 計測完了 (`bench/quick_baseline.txt` の `binary_size_bytes`
row、 release build = 820,568 bytes 近辺)、 これが本 ADR の Tier 0
overhead measurement の reference baseline。

## Decision

### D1: cljw build single mode、 flag ゼロ

```sh
cljw build app.clj -o app
  → app  (single binary、 source 含めない)
```

`--debug` / `--source` / `--aot` / `--no-symbols` 等の flag を **全廃止**。
default 動作のみ。 user は何も意識しない。 dev / REPL は別 command:

```sh
cljw file.clj             # direct source eval
cljw repl                 # interactive REPL
cljw render-error err.edn # post-mortem decode (D11)
```

build mode と dev mode を完全独立に運用、 dev 体験は source 直 eval で
snippet 描画含めて完全。

### D2: bytecode embed default、 source 含めない、 sidecar なし

binary 内容:

| 項目                       | 必須?    | 備考                                               |
|----------------------------|----------|----------------------------------------------------|
| cljw runtime               | 必須     | Reader + Compiler + VM + GC 同梱                   |
| Bootstrap cache (bytecode) | 必須     | core lib build-time bytecode 化                    |
| User code bytecode         | 必須     | source の 0.8-1.2x                                 |
| Tier 0 metadata            | 必須     | bytecode の 5-10% (D3)                             |
| build-id                   | 必須     | git SHA + cljw version (D5)                        |
| Source (full)              | 含めない | dev 時の手元 git source + cljw render-error で復元 |

**cljw runtime には Reader + Compiler が常時同梱** (= bytecode embed
default でも runtime の `(eval ...)` / `(load-string ...)` / `defmacro`
の macroexpand のため必須)、 bootstrap cache restore path で Reader +
Compiler を bypass。

### D3: Tier 0 metadata (var/file/line/col interned tables) 常時 ON

各 bytecode op に対応する:
- var name (interned string table)
- file path (interned string table)
- line number (delta-encoded)
- col number (delta-encoded)

= 最小限の symbolication 情報のみ、 source 全文は含めない。 stack
trace の line/col + var name を production 環境でも無条件に取れる。

size budget: 5-10% overhead (Phase 6.16.a-1 baseline = ~820 KB release
binary に対する measurement reference)。 超えた場合 ADR-0034 amendment
で削減策。

### D4: Deno-style binary trailer 形式 + bootstrap cache build.zig 統合

```
[cljw runtime binary (Mach-O / ELF / Wasm)]
[bootstrap cache: serialized bytecode + var table + ns table]
[user app bytecode payload]
[Tier 0 metadata table]
[build-id block]
[u64 size of payload+metadata+build-id]
["CLJC" magic 4 bytes]
```

起動 flow:
1. cljw runtime が argv[0] から自身を open
2. 末尾 4 bytes を read、 magic check
3. u64 size を read、 payload + metadata + build-id 領域を mmap
4. bootstrap cache restore (~3-4ms、 cw v0 evidence)
5. user app bytecode → VM dispatch
6. (error 時) Tier 0 metadata から var/file/line/col を引いて trace 構築

bootstrap cache は build.zig 時に `cache_gen.zig` が全
`src/lang/clj/clojure/*.clj` を eval して VM state を serialize、
binary に `@embedFile` (cw v0 Phase 32.2-32.3 形態維持)。

### D5: build-id 形式

```edn
{:git    "abc1234567890abcdef"      ; commit SHA (40 chars or short)
 :cljw   "0.1.0"                     ; cljw version (semver)
 :built  #inst "2026-05-25T12:34:56Z"}
```

map 形式で binary 内に EDN として埋め込み。 error event 出力時に必ず
含める (D8)。 dev 側 post-mortem (`cljw render-error` D11) が `:git` SHA
で `git checkout` 同期を user に案内、 `:cljw` で decoder archive
dispatch (D11)。

### D6: format version policy = ABI commitment 不要

cljw build の output は **self-contained**: runtime + bytecode が同
binary に接着、 mismatch 構造的に発生しない (= Deno / Bun / Go と同
pattern)。

- bytecode format は **internal-only**、 user 視点では存在しない
- format version up は新 cljw build で再生成すれば済む、 既存 binary
  は古い cljw runtime で永久動作
- **format version policy 不要**、 ABI commitment 不要

唯一の互換性責任: **`cljw render-error` decoder の永久互換性**
(D11 archive policy)。

### D7: error output = stream-separated (TTY=human / pipe=structured EDN one-line)

stderr は **常に 1 つの format**:

| 環境              | format                                   | 用途                             |
|-------------------|------------------------------------------|----------------------------------|
| TTY (interactive) | human readable (色付き、 babashka-style) | 対話開発、 REPL、 dev binary     |
| pipe (非 TTY)     | structured EDN (1 event = 1 line)        | production logs、 log aggregator |

混合しない。 pipe で渡せば直接 jq/grep/awk で機械処理可能 (EDN→JSON
1 段変換)。

### D8: EDN event schema

```edn
{:phase      :runtime | :analysis | :read
 :category   :type_error | :name_error | :arity_error | :private_access_error | ...
 :message    "split: expected string, got nil"
 :file       "src/handlers/auth.clj"
 :line       42
 :col        8
 :var        clojure.string/split        ; symbol
 :ex-data    {:input nil, :sep #"\s+"}   ; user attached data
 :trace      [{:var handlers.auth/parse-token   :file "..." :line 42 :col 8}
              {:var handlers.auth/login-handler :file "..." :line 18 :col 3}]
 :build-id   {:git "abc1234" :cljw "0.1.0" :built #inst "2026-05-25T12:34:56Z"}
 :timestamp  #inst "2026-05-25T12:35:01.234Z"
 :request-id "abc-123"      ; optional、 user runtime が `cljw.error/with-context` で injectable
 :trace-id   "xyz-456"}     ; 同上
```

完全 spec は v5 Appendix C 参照。 1 event = 1 line (改行は `\\n`
escape)、 top-level key 順固定 (`:phase :category :message :file :line
:col :var :ex-data :trace :build-id :timestamp <user-injection>`)。

### D9: env var override

```
CLJW_ERROR_FORMAT=human       # 強制 human
CLJW_ERROR_FORMAT=structured  # 強制 structured EDN
CLJW_ERROR_FORMAT=both        # 両方 (human stderr + structured CLJW_ERROR_LOG)
CLJW_ERROR_LOG=/var/log/cljw.edn   # structured を別 file へ、 stderr は human
```

Phase 14 v0.1.0 release で stable spec として lock (D-066)。

### D10: human renderer = cw v1 既存 babashka-style 流用

cw v1 現状の renderer (`src/runtime/error/render.zig` 相当) を流用、
trace 描画追加のみ。 D7 の TTY-aware default で structured EDN trailer
を混合しない (= human stderr / structured `CLJW_ERROR_LOG` は別 channel、
混合 parse 問題なし)。

### D11: `cljw render-error` post-mortem tool + decoder archive

CLI:
```sh
cljw render-error err.edn
  → 1 event ごと human render 出力 (TTY なら色付き、 pipe なら plain)
  → :file の source が手元 git repo にあれば snippet + caret 復元

cljw render-error --source-from-git $sha err.edn
  → 指定 SHA で git checkout → source snippet 復元

cljw render-error --format json err.edn
  → EDN を JSON に変換出力 (log aggregator 用)
```

decoder archive policy:
- `cljw-formats/<version>.edn` archive を repo 内に永久保管
- 例: `cljw-formats/0.1.0.edn` には 「op_call = 0x10、 op_const = 0x11、
  ...」 等の opcode table
- `cljw render-error` は build-id `:cljw` を読んで対応 archive を load
  して decode
- 新 cljw release ごと archive 追加、 **削除しない**
- = decoder 単方向永久互換性、 encoder 互換性責任なし

Phase 12 entry で internal API + decoder skeleton 着地 (D-064)、 Phase
14 v0.1.0 release で `cljw-formats/0.1.0.edn` archive lock (以降 add
only)。

## v0.1.0 build envelope + build-time-eval semantics (amendment 1)

D4 fixes the *full* trailer layout (bootstrap cache + user bytecode
+ Tier 0 metadata + build-id + size + magic). At the v0.1.0
`cljw build` landing (D-100(b), row 14.11(b)) the **minimal correct
subset** ships first; the remaining D4 blocks are deferred per D6.
This amendment fixes the two things D4 left unspecified — the
**payload envelope framing** and the **build-time evaluation
semantics** — and records the deferral of the additive blocks so
D3's "Tier 0 metadata 常時 ON" is not silently dropped.

### A1-D1: payload = sequence of chunks (not a single `(do …)` chunk)

The compiler produces **one `BytecodeChunk` per top-level form**
(`vm_compiler.compile(rt, arena, node)`). A file is NOT wrapped in
a synthetic `(do …)` — `analyzeDo` (`special_forms.zig`) analyzes
all subforms in a single pass with no intervening eval, so an
in-file `(defmacro m …)` / `(require [x :as a])` followed by `(m)`
/ `(a/f)` would be analyzed before the macro / alias is registered
(broken). The build instead mirrors the runner's per-form loop and
emits a **sequence** of chunks:

```
[u32 n_chunks, LE]
n_chunks × ( [u32 chunk_len, LE] [chunk_bytes (serializeChunk v2)] )
```

Per-chunk length framing is required because the v2 chunk format
is not self-terminating for back-to-back concatenation. This
**payload envelope** is archived in `cljw-formats/0.1.0.edn` as a
`:payload-envelope` entry **distinct** from the `:chunk-format` v2
entry, so framing and chunk semantics pin independently (matches
D6 / D11 decoder-permanence intent).

### A1-D2: build-time eval of top-level forms (Clojure AOT semantics)

The build loop is the runner's loop (`src/app/runner.zig`
L84-103) with a chunk sink: per top-level form
`read → analyzeForm → vm_compiler.compile (→ append chunk) →
driver.evalForm`. The **eval step is mandatory** — it registers
macros / requires / defs into `env` + `macro_table` so the next
form analyzes against an evolved environment. This matches Clojure
AOT (`compile` evaluates top-level forms as it compiles them).

**Consequence (documented, not a defect):** a top-level
side-effecting form (e.g. `(println "hi")`) runs **during the
build**, not only at run time — identical to Clojure AOT. This is
surfaced in `cljw build` help text. The alternative (a classifier
that evals only "env-shaping" forms and skips side-effecting ones)
is undecidable in general and Clojure-divergent — see Alternatives
amendment-1 Alt C. A build-time form that *throws* aborts the
artifact with a non-zero exit + EDN error event (D11); it never
embeds a half-payload.

**F-009:** the per-form compile-then-eval loop is the same code
`runner.zig` runs; it is factored into a neutral helper that both
`runner.zig` (run mode, discards chunks) and `src/app/builder.zig`
(build mode, collects chunks + aborts-on-throw) call, so run-mode
and build-mode cannot drift.

### A1-D3: deferred D4 blocks at v0.1.0 (tracked, not dropped)

The v0.1.0 artifact ships `[runtime binary][payload envelope][u64
payload_len][magic]` only. Deferred per D6 (format is not
ABI-committed; a new `cljw build` regenerates, and a future
archive entry decodes the richer format):

- **bootstrap cache block** — the built binary re-runs
  `bootstrap.loadCore` at startup (same `@embedFile`'d core
  sources); the cold-start <12 ms target (D-100(d)) was already met
  without a serialized cache (ebf2979b).
- **Tier 0 metadata block** (D3 常時 ON) — deferred; stack-trace
  symbolication for built binaries lands post-v0.1.0.
- **build-id block** (D5) — deferred.

Tracked by **D-131** so D3's always-on contract has an explicit
recall owner rather than a silent gap.

### A1-D4: trailer magic

Trailer magic = **`"CLJC"`** (D4 literal), kept distinct from the
serializer's internal chunk magic `"CLJW"` (`serialize.zig` L54),
so the tail-detection key never aliases the payload head.

## Alternatives considered

Devil's-advocate fork (general-purpose subagent、 fresh context、
2026-05-25 issuance、 F-001/F-004/F-005/F-006/F-009 envelope 内)
output verbatim:

#### Alt 1: cw v0 Phase 32 形態踏襲 (smallest-diff)

`cljw build` の出力を **source bundle default + `--bytecode` flag opt-in** とし、 Tier 0 metadata table・structured EDN error event・`cljw render-error` post-mortem tool のいずれも導入しない。 error 出力は既存の babashka-style human renderer のみ。 trailer 形式は cw v0 Phase 32.2-32.3 をそのまま継承し、 build-id は git SHA 単独 (map 化なし)。

- **利点**: 実装差分が最小 (v0 → v1 移行 cost が低い)、 source bundle により bundled artifact が `cljw -e` で即 inspectable、 schema 議論を Phase 後送りにできる。
- **欠点**: production 配布で source 同梱が IP 漏洩 vector になる、 runtime error の machine-parseable 出力が存在しないため CI / log aggregation 統合に都度 ad-hoc parser が必要、 Tier 0 metadata 不在で stack trace の file/line/col 情報が空白、 post-mortem tool 不在で format version drift 発生時に過去 artifact を decode できない。
- **F-NNN 関係**: F-001 / F-004 / F-005 / F-006 とは独立。 F-009 (feature-implementation neutrality) には準拠 — 既存形態の延命であって新規 feature 縛りなし。
- **F-NNN violation**: なし。

#### Alt 2: ADR-0034 本提案 (D1-D11) (finished-form-clean)

`cljw build` を flag ゼロの単一 mode に固定し、 bytecode embed default + Tier 0 metadata 常時 ON + Deno-style trailer + map 形式 build-id + stream-separated error output (TTY=human / pipe=EDN one-line) + `cljw render-error` post-mortem decoder archive を採用。 format version policy は ABI commitment 放棄 (self-contained binary により mismatch が構造的に発生しない) で、 互換性責任を decoder 側に集中。

- **利点**: distribution artifact が 1 binary に確定し flag 選択の cognitive cost ゼロ、 EDN event schema により CI / log pipeline が初日から structured parse 可能、 Tier 0 metadata の常時 ON 化で stack trace の file/line/col が空白にならず error UX が JVM Clojure 水準に到達、 post-mortem decoder archive により過去 build-id を持つ artifact を future cljw で reproducibly decode 可能、 build-id map (`:git :cljw :built`) で release 追跡が EDN 解析だけで完結。
- **欠点**: Tier 0 metadata の size budget (5-10%) を恒久的に支払う、 EDN schema が `:phase :category :message :file :line :col :var :ex-data :trace :build-id :timestamp` の 11 key 固定で初期 design の拘束が強い (key 追加は decoder archive bump を要する)、 decoder archive (`cljw-formats/<version>.edn`) を v0.1.0 release で lock する commitment が発生し、 archive の forward maintenance が future Phase の永続 cost、 stream-separated output は TTY 判定 (`isatty(2)`) に依存し redirect 経由の subtle pipeline で human 形式が EDN consumer に混入する事故 surface が残る。
- **F-NNN 関係**: F-001 (zwasm v2 library import) — cljw user code path と zwasm wasm execution path の分離を破らない。 F-004 (NaN-box 64 slot) — metadata table は heap interned で NaN-box slot を消費しない。 F-005 (数値タワー JVM 表面互換) — error event `:ex-data` に numeric 値が乗っても tower semantics に影響なし。 F-006 (mark-sweep + 3-layer allocator) — Tier 0 table は permanent allocator tier に置くことで GC root に依存しない。 F-009 — feature 列挙ではなく単一 build mode 固定なので neutrality に準拠。
- **F-NNN violation**: なし。

#### Alt 3: AOT native + JIT 完全廃止 (wildcard)

`cljw build` を **WebAssembly AOT compile → ELF/Mach-O native binary 生成 ahead-of-time** に置き換え、 runtime の wasm interpreter / JIT path を artifact からは完全に剥がす (wasmtime-style AOT pre-compilation を build-time に強制)。 bytecode embed は不要となり、 Tier 0 metadata は DWARF debug section に流し込む。 EDN error event は標準入出力に streaming で出すが、 decoder archive は DWARF version dispatch に統合する。

- **利点**: artifact 起動 latency が interpreter loop ゼロで cold-start near-zero、 OS-native debugger (lldb / gdb) が DWARF 経由でそのまま stack trace を解釈し外部 tooling 統合が無料、 trailer format の独自 versioning を捨てて ELF/Mach-O の既存規格に乗れる、 distribution size が trailer-less で純粋 binary。
- **欠点**: cljw user code の eval / REPL / dynamic var 再定義 が AOT 前提と root から衝突 (Clojure の dynamic recompilation surface を放棄することになる)、 DWARF への metadata mapping は platform-specific (Mac/Linux/Windows) で host abstraction の負担が爆発、 wasm 実行 path を build artifact から剥がすと cljw user code と zwasm wasm execution の path 分離が崩れる。
- **F-NNN 関係**: **F-001 と直接衝突** — cljw が zwasm v2 を library として import し cljw user code path と wasm execution path を分離する前提が、 wasm AOT を cljw 側の build pipeline に組み込むことで融合してしまう。 F-004 / F-005 / F-006 とは独立に解決可能。 F-009 は build mode 単一固定の点で本提案と同等。
- **F-NNN violation**: **あり (F-001)**。 zwasm v2 library import 前提を維持しながら AOT native binary を出すことは、 Clojure dynamic eval surface (F-009 の neutrality に含まれる REPL/eval 機能) を犠牲にせず実現する path が現時点で見えない。 finished-form-clean を志向する場合でも、 F-001 の amendment は user action であり、 主 loop は本 wildcard を採用すべきではない (= 記録のみ、 採用候補から除外)。

### Amendment-1 Devil's-advocate fork (2026-05-29, D-100(b) payload format + build semantics, F-001/F-002/F-009 envelope) — verbatim

**F-NNN gate check (leading entry):** None of the three shapes below requires violating F-001, F-002, or F-009. F-009 note: the build loop's *semantics* (read→analyze→compile→eval per top-level form) are the runner's existing pipeline (`src/app/runner.zig` L84-103) already living in neutral `src/eval/` + `src/lang/`. The builder (`src/app/`) is a Layer-3 driver that *orchestrates* those neutral pieces and appends the trailer; no impl logic needs to move. One caveat surfaced (see Alt B (c)): the per-form-eval loop is the same loop `runner.zig` runs, so the finished form should **extract that loop into a neutral helper** rather than have `builder.zig` re-implement it — that is the only F-009-relevant decision here, and it is satisfiable.

#### Alt A — Smallest-diff: single-chunk `(do …)` wrap, ungated landing

(a) **Concrete shape.** `builder.zig` reads the file, wraps all top-level forms in one synthetic `(do f1 f2 … fn)` Form, calls `analyzeForm` once → `analyzeDo` produces one `DoNode`, `vm_compiler.compile` produces **one** `BytecodeChunk`. Payload = `serializeChunk(chunk)` bytes verbatim (existing v2 format, no new framing). Trailer `[u64 payload_len]["CLJC"]` appended to the cljw binary. Startup: read tail, `deserializeChunk`, VM-run the single chunk. Landing: ungated via ADR-0015 amendment 5.

(b) **Better than the others.** Zero new payload framing — reuses the existing single-chunk serializer untouched, so the `cljw-formats/0.1.0.edn` archive (D-100(e)) records exactly the v2 chunk format already serialized, no count-header byte to archive. Smallest startup path (one deserialize, one run).

(c) **Breaks / risks.** **This is the established-broken shape:** `analyzeDo` analyzes all subforms in a single pass with no intervening eval, so an in-file `(defmacro m …)` followed by `(m)`, or `(require [x :as a])` followed by `(a/f)`, fails at analyze time. Diverges from Clojure AOT. It is not a smaller path to the *same* finished form — it is a path to a **different, broken** finished form, so under F-002 the smallest-diff tie-breaker does not apply. Not recommendable except as the throwaway red-test baseline that motivates Alt B.

#### Alt B — Finished-form-clean: sequence-of-chunks + per-form compile-then-eval, ungated landing

(a) **Concrete shape.** Build loop mirrors `runner.zig` L84-103, extracted into a neutral helper both `builder.zig` and `runner.zig` share (F-009): per top-level form `reader.read → analyzeForm → vm_compiler.compile → append chunk → driver.evalForm` (env evolves: macros/requires/defs register for form N+1). Payload `[u32 n_chunks]` then `n_chunks × [u32 chunk_len][chunk_bytes]`. Per-chunk length framing required (v2 chunk has no self-terminating end marker). Startup: read trailer → slice payload → read `n_chunks` → loop deserialize+VM-run each in order. Matches Clojure AOT. Landing ungated, ADR-0015 amendment 5.

(b) **Better than the others.** Only shape *correct* for in-file macros + require-then-use, the realistic `cljw build app.clj` corpus (D-121 just landed Java-static dispatch precisely so build-able corpora can reference statics). Sharing the compile-unit loop with `runner.zig` removes run-vs-build drift. Per-chunk framing also forward-useful for D-103 (per-chunk peephole-version concerns localize).

(c) **Breaks / risks.** (1) **Build-time side effects:** a top-level `(println "hi")` runs during the build — exactly Clojure AOT (`*compile-files*` runs top-level forms incl. side effects). Acceptable + expected, but MUST be documented in ADR Consequences + `cljw build` help. (2) **Archive interaction:** the `n_chunks` + per-chunk-`len` framing is a new outer envelope around the v2 chunk format; archive it as a **separate** `:payload-envelope` entry distinct from the `:chunk-format` v2 entry, so envelope framing and chunk semantics pin independently per ADR-0034 decoder-permanence (option ii-1, recommended). (3) build-time eval can *throw*; the builder must surface a build error (non-zero exit, EDN event per D11), not embed a half-payload.

#### Alt C — Wildcard: analyze-only + separate macro/require registration pass (no build-time side effects)

(a) **Concrete shape.** Two-pass build with no eval of arbitrary top-level forms. Pass 1 *selectively* evaluates only env-shaping forms (`defmacro`, `require`/`use`/`import`, macro-referenced `def`), skipping side-effecting forms; Pass 2 re-analyzes + compiles every form against the populated env. Side effects run only at run time. Framing identical to Alt B.

(b) **Better than the others.** The only shape that resolves in-file macros/requires **without** build-time side effects. Cleaner mental model for "build = compile, run = execute".

(c) **Breaks / risks — this is the trap.** Classifying "env-shaping vs side-effecting" is **undecidable in general** and diverges from Clojure. `(def x (compute-config))` where a downstream `(defmacro m [] @x)` depends on the side-effecting def — Clojure runs *everything* at compile time top-to-bottom; macros can depend on prior side effects. Alt C must either approximate the classifier and silently mis-handle the dependent-def case (a permanent-no-op / silent-semantics-drop smell — successful build, macro expanded against stale `x`), or re-introduce full eval and collapse into Alt B. It reaches a **Clojure-divergent** finished form the owner would unwind. Under F-002 this disqualifies it. Build-time side effects (Alt B's "cost") are not a defect to engineer away — they are the *correct Clojure AOT semantics*.

#### Recommendation (non-binding)

**Alt B.** Only shape reaching the correct Clojure-AOT finished form for the realistic corpus. Alt A reaches a *broken* finished form; Alt C reaches a *Clojure-divergent* one by suppressing side effects that are actually correct. Per F-002 the smallest-diff tie-breaker (Alt A's only virtue) does not apply — candidates reach **different** finished forms, the correct one wins regardless of extra framing bytes + the shared-loop extraction. Specifics: (i) build-time eval is acceptable + *required*, document it; (ii) `[u32 n_chunks]` + per-chunk `[u32 chunk_len]` framing, archived as a separate `:payload-envelope` entry; (iii) ungated landing risk low — `build` has no `phase_at_least_14` dependency, mirror ADR-0015 amendment 3 with amendment 5. **Shared-loop extraction (F-009) is mandatory, not optional** — the per-form compile-then-eval loop must be the same code `runner.zig` runs, in a neutral helper both call; re-implementing it in `builder.zig` invites run-vs-build drift.

## fn_val constant serialization (amendment 2)

Amendment 1 chose the per-form compile-then-eval build loop + payload
envelope. Implementing `cljw build` (D-100(b) step 3b) surfaced a gap the
amendment-1 survey missed (Step 0.6 ~80% boundary): the bytecode
serializer (`serialize.zig`, "D-100(a) Discharged") **rejects `fn_val`
constants** with `UnsupportedValueTag`, but the VM compiler emits every
user function as an `fn_val` CONSTANT (`op_make_fn`'s operand indexes a
`fn_val` in the chunk constant pool, `vm/compiler.zig:236-242`). So as
landed, `cljw build` could not serialize ANY program containing
`(defn …)` / `(fn* …)` / `(defmacro …)` — i.e. every realistic program.
A v0.1.0 build command that fails on `(defn -main [] …)` is a hollow
deliverable. Per F-002 (finished form wins; cycle/diff size is not a
constraint) and the user's standing directive ("最終的にうつくしいものを
完成させる … 根本的に計画して対処"), this amendment closes the gap rather
than scoping around it.

### A2-D1: v0.1.0 `cljw build` serializes function constants

`writeValue` / `readValue` gain an `fn_val` arm. A function constant is
serialized by its CONTENTS (F-004 — never the heap pointer): `slot_base`
+ each method's `arity` / `has_rest` + the method's bytecode body, which
is itself a `BytecodeChunk` serialized **recursively** via the existing
`serializeChunk` (the recursion is the natural shape — a method body is a
chunk). A nested `fn*` inside a method body is a further `fn_val` constant
in that sub-chunk, handled by the same recursion to arbitrary depth.

### A2-D2: closure capture is the only unserializable case (invariant guard)

A `fn_val` that appears as a compile-time CONSTANT always has
`closure_bindings == null`: a runtime closure (bindings filled from live
locals) is created by `op_make_fn` at call time, never embedded as a
constant. A `slot_base > 0` constant is a *template* (`closure_bindings
== null`); it serializes fine and `op_make_fn` fills its bindings at
runtime exactly as for a freshly-compiled template. Therefore the serializer
raises an explicit error ONLY when `closure_bindings != null` — a true
invariant guard (a corrupt/impossible constant), not a feature gate. No
silent-drop (`no_op_stub_forbidden` satisfied).

### A2-D3: deserialized-function lifetime + reconstruction

- The reconstructed `Function` is `rt.gpa`-allocated + `trackHeap`'d +
  `closure_bindings = null` — identical to a compiled top-level fn, so
  `freeFunction` is **unchanged** (frees the methods slice + struct).
- The method bytecode sub-chunks are owned by the **same `allocator`**
  that owns the parent chunk; `freeChunk` recurses into `fn_val`
  constants and frees their sub-chunks. The recursion reads
  `fn_val.methods[i].bytecode` (the gpa methods slice), which is valid as
  long as `freeChunk`/`freeEnvelope` runs **before** `rt.deinit`
  (freeFunction frees the methods slice). The run sequence + defer-LIFO
  satisfy this ordering naturally; it is documented at the `freeChunk`
  recursion site.
- `FunctionMethod.body` (a `*const Node`) is only read by the tree_walk
  backend; the VM path uses `bytecode`. A deserialized fn has no source
  Node, so its methods point at a shared **immortal sentinel** Node; a
  pointer-equality guard at the tree_walk fn-body site raises a clear
  internal error if it is ever reached (it is not — deserialized fns are
  VM-only, `bytecode != null`).
- Method **param-name** strings are NOT serialized (reconstructed as an
  empty slice). Param names are debug-only (error-frame labels);
  dispatch uses the `arity` field. AOT-built functions therefore show no
  param-name labels in error frames — a transparent minor fidelity gap,
  not a semantics drop, tracked by **D-139** for a later cycle.

### A2-D4: archive interaction (D-100(e))

`cljw-formats/0.1.0.edn`'s `:chunk-format` v2 entry gains the `fn_val`
(0x0F) ValueTag wire shape. Because a method body is a nested chunk, the
archive notes the recursion (a chunk's constant pool may contain a
`fn_val` whose methods are themselves chunks). No new top-level format
entry — `fn_val` is a constant kind within the existing v2 chunk format.

### Amendment-2 Devil's-advocate fork (2026-05-29, fn_val serialization scope, F-002/F-004/F-009/F-010 envelope) — verbatim

## Alternatives considered

### Alt A — smallest-diff: keep rejecting `fn_val`, document the floor

Leave `serialize.zig`'s `UnsupportedValueTag` rejection on `fn_val` exactly as-is; document `cljw build` in v0.1.0 as "programs whose top-level reachable constant pool contains no user `fn` constants" and file a debt row (D-NNN) carrying full fn serialization to the post-v0.1.0 quality/coverage loop (F-010's second half). What it does better: zero new serialization surface, zero deserialization-lifetime risk, smallest archive format, and the explicit error means no permanent-no-op violation (the user sees `UnsupportedValueTag`, not a silently broken artifact). What it breaks: `(defn …)` / `(fn* …)` / `(defmacro …)` are the first thing any non-toy `.clj` contains, so `cljw build` can only build arithmetic/`def`-of-literal scripts — a v0.1.0 deliverable that fails on `(defn -main [] …)` is a hollow feature in all but name. The explicit error keeps it honest, but "honest about not working" is not the same as "works"; D-100(b) was scoped as a real build command, and this reduces it to a demo.

### Alt B — finished-form-clean: full `fn_val` serialization

Serialize `fn_val` constants fully: write `header`, `slot_base`, the `methods[]` array (each method's `arity` / `has_rest` / `params[][]const u8` strings + recursive `serializeChunk(method.bytecode.?)`), and the `variadic` method if present; on deserialize, reconstruct a `Function` with `closure_bindings = null`, a sentinel/placeholder `body` Node (the VM path reads only `bytecode`, never `body` — fact (4)), arena-or-GC-owned `methods` slices, and recursively-deserialized sub-chunks tracked for `freeChunk` recursion + GC marking. Raise an explicit error ONLY on the genuinely-impossible `closure_bindings != null` case (fact (1): a compile-time constant can never carry runtime closure bindings, so this branch is a corruption/invariant guard, not a feature gate). What it does better: `cljw build` builds realistic programs (the whole point of D-100(b)); the recursion is the natural shape since `method.bytecode` is itself a `BytecodeChunk` already serializable by the existing `serializeChunk`; it stays in-zone (Function lives in `eval/backend/tree_walk.zig`, same Layer 1 — F-009 OK) and serializes contents not pointers (F-004 OK). What it breaks/risks: (1) lifetime — deserialized sub-chunks and `methods`/`params` slices need a clear owner (deserialize-arena vs GC heap) or they leak / dangle when the embedded payload's top chunk is freed; (2) the sentinel `body` Node must be a shared immortal singleton, never freed, never walked, or a future tree_walk-on-deserialized-fn path would segfault — needs a guard/assert; (3) `defmacro` carries macro metadata (the `:macro` flag lives on the Var, not the Function, so verify the build path captures it where defmacro is recorded — if macro-ness rides on Function it must serialize too); (4) `slot_base > 0` nested templates serialize fine as constants (bindings filled at runtime by `op_make_fn`), but round-trip tests must cover the nested-template case explicitly.

### Alt C — wildcard: embed source text, re-analyze+compile at startup

Don't serialize bytecode at all. Embed the original `.clj` source text (or the read forms) in the trailer and re-run the existing read → analyze → compile pipeline at process startup, producing fresh chunks (and thus fresh `fn_val` constants) in-process — sidestepping fn serialization entirely. Tradeoff: it does better on format simplicity (the trailer is just bytes of source, no recursive chunk schema, no Function reconstruction, no lifetime/sentinel-body problem, and it can never silently drop semantics because it runs the identical compile path) and it trivially handles `defmacro`/closures/everything the live runtime handles. But it breaks the stated deliverable shape ("serialized bytecode payload", D-100(a) Discharged) — startup now pays full analyze+compile cost on every run (defeating the precompile rationale), the binary must ship the entire compiler reachable at startup (already true, but now load-bearing for `cljw build`), and it makes the "compiled artifact" indistinguishable from `cljw run app.clj` plus a trailer, i.e. it quietly demotes D-100(a)'s serializer to dead code on the build path. A middle variant (a fn-proto table à la cw v0: hoist all `fn_val`s into a flat indexed table, store index references inline, deserialize the table first then patch references) avoids inline recursion and dedups shared protos, but adds a two-pass serializer + reference-fixup pass whose complexity exceeds Alt B's straightforward recursion for no finished-form benefit at v0.1.0 scale.

### Recommendation

Per F-002 (finished-form cleanliness wins; cycle/diff/LOC is not a constraint), **Alt B**. It is the only option that makes `cljw build` actually build the programs the deliverable promises, it reuses the already-recursive `serializeChunk` shape rather than inventing a parallel format, and the one explicit error it keeps (`closure_bindings != null`) is a true invariant guard rather than a feature gate — so it satisfies permanent-no-op-forbidden honestly. Alt A is the Cycle-budget-defer smell wearing a debt row; Alt C's source-re-compile path is genuinely clean but contradicts D-100(a)'s already-discharged bytecode-payload shape and demotes the serializer to dead code, so it would require re-opening D-100(a) rather than completing D-100(b). The main loop is not bound by this recommendation, but choosing Alt A or C on size grounds would itself be the forbidden defer smell. (Note: whichever is chosen, the lifetime/owner decision for deserialized sub-chunks and the immortal-sentinel-`body` guard are the two load-bearing details Alt B must nail in the same cycle.)

### Amendment-2 decision

**Alt B selected** (matches the DA recommendation). Divergence from the DA's
Alt B sketch: param-name strings are NOT serialized at v0.1.0 (A2-D3 —
reconstructed empty, tracked by D-139), because the param-string lifetime
would otherwise force a `freeFunction` ownership flag for no
dispatch-correctness benefit (param names are debug-only). The sub-chunk
lifetime is resolved via `freeChunk` recursion with documented
freeEnvelope-before-rt.deinit ordering (A2-D3), not an arena, keeping the
existing allocator-explicit deserialize contract. The DA's concern (3)
(defmacro macro metadata) is a non-issue: macro-ness is Var-level and only
consulted at analyze time, which has already happened at build time; a
deserialized macro fn is harmless dead weight at runtime.

## Selection rationale

Alt 2 (本提案) を選択。 F-002 (finished-form wins) + cljw メインターゲット
が エッジ実行であり cold-start < 5ms 要件下で source bundle 形態が
許容不可、 + Tier 0 metadata + structured EDN により ops observability
が初日から成立する利点が決定的。 Alt 1 は IP 漏洩 vector + machine-
parseable error 不在で production 適合性低い。 Alt 3 は F-001 violation
(zwasm 依存方向逆転 + dynamic eval surface 喪失) で envelope 外。

Alt 2 の Breaks 5 件は受容コストとして識別:
- (i) 5-10% size 恒久支払 → Phase 6.16.a-1 baseline (820KB) に対し
  ~50KB overhead = エッジ 10MB platform 制約に対しても余裕
- (ii) EDN schema 11 key 固定 → key 追加は ADR-0034 amendment + decoder
  archive bump で対応、 cost は明示的
- (iii) decoder archive forward maintenance → 削除 forbidden / add only、
  v0.1.0 release 時に initial archive 確定後は cycle ごとに 1 entry
  追加するだけ、 amortise 容易
- (iv) human / EDN 混入事故 → env var `CLJW_ERROR_FORMAT` で強制可能、
  default は TTY 判定だが ops が pipeline 設計時に明示 override 推奨
- (v) Phase 12 entry でこれら 11 D-items を一括 implement する必要 →
  D-064 (post-mortem) + D-066 (env var spec) + ADR-0033 cluster
  workflow で段階着地 path 設計済

## Consequences

- **Phase 12 entry deliverable**: bytecode embed pipeline 完成 (`cljw
  build app.clj -o app` internal API、 single mode、 flag ゼロ) +
  Tier 0 metadata serializer/deserializer + build-id injection +
  Deno-style binary trailer + bootstrap cache build.zig 統合 +
  `cljw render-error` internal API + `cljw-formats/<version>.edn`
  archive 初版 + error output stream-separated (TTY=human / pipe=EDN)
  + env var recognition
- **Phase 14 entry deliverable (v0.1.0 release)**: `cljw build` /
  `cljw render-error` CLI surface 公開 + `cljw-formats/0.1.0.edn`
  archive lock + `CLJW_ERROR_FORMAT` / `CLJW_ERROR_LOG` env var
  公式 spec 化 + `cljw.error/with-context` macro 公開
- **Phase 16 entry**: ClojureScript transpiler が `defn-` + `-name`
  leaf を JS interop に置換するレイヤで `^:zig-leaf` metadata を読む
  (ADR-0033 D4 + D-068 と整合); Wasm Component output が同 binary
  trailer 形式を踏襲可能
- **Phase 17 entry**: JIT go の場合、 D6 (ABI commitment 不要) の下で
  bytecode に source-level metadata 保持 option を broad JIT 用に追加
  可能 (ABI 維持しつつ拡張)、 narrow JIT は完全直交 (ADR-0033 D10 と
  整合)
- placement.yaml + compat_tiers.yaml schema は本 ADR と独立 (= placement
  は ADR-0033、 compat_tiers は ADR-0029)
- format version 概念を撤回することで `version_field` / `magic upgrade`
  系の implementation cost を回避、 decoder archive の add-only policy
  で互換性責任を decoder 側に集中
- EDN event schema の固定 11 key は user runtime injection (`:request-
  id` 等) を許す形で拡張可能、 schema 自体の breaking change は ADR-
  0034 amendment

## Affected files

- `.dev/ROADMAP.md` §9.14 / §9.16 — 既に v5 wiring (757a0b5) で
  expansion 済 (本 ADR は SSOT 化)
- `.dev/debt.md` D-064 (decoder archive) / D-066 (env var spec) — 既に
  起票済 (757a0b5)
- `private/notes/clj_vs_zig_split_proposal_v5.md` §11-§14 + §16.1 + §19.2
  + App C (EDN schema 完全 spec) — 本 ADR の SSOT

Phase 12 entry 以降の Affected files (本 cycle 時点では未着地):

- `src/app/builder.zig` (Phase 12 着地、 build-id 埋め込み + bytecode
  serialize 完成)
- `src/runtime/error/render.zig` (TTY-aware + EDN serializer 拡張)
- `src/runtime/error/event.zig` (新規、 EDN event schema 実装)
- `src/app/render_error.zig` (新規、 post-mortem tool entry point)
- `cljw-formats/0.1.0.edn` (新規 archive、 v0.1.0 release 時に lock)
- `build.zig` (cache_gen + build-id injection 拡張)

## Revision history

- 2026-05-25 issued + accepted with Devil's-advocate fork
  (general-purpose subagent、 fresh context、 F-NNN envelope 内 3
  alternatives 取得 verbatim、 Alt 2 採択、 Alt 3 が F-001 violation
  寄りの旨を明示)。 v5 plan §11-§14 + §19.2 (1593 行、 self-
  contained) を SSOT として参照、 Tier 0 metadata size baseline
  measurement (Phase 6.16.a-1 d35dc3b terminus) を起票 prerequisite
  として参照。
- 2026-05-29 (amendment 1): D-100(b) `cljw build app.clj -o app`
  landing. Added "v0.1.0 build envelope + build-time-eval
  semantics" section (A1-D1..A1-D4): payload = sequence of v2
  chunks with `[u32 n_chunks]` + per-chunk `[u32 len]` framing
  (NOT a single `(do …)` chunk — `analyzeDo` single-pass analysis
  breaks in-file macros/requires); build loop = runner's per-form
  read→analyze→compile→eval (Clojure AOT, build-time side effects
  documented); D4 bootstrap-cache / Tier-0-metadata / build-id
  blocks deferred at v0.1.0 per D6 and tracked by **D-131** so the
  D3 常時-ON contract is not silently dropped; trailer magic
  `"CLJC"` kept distinct from chunk magic `"CLJW"`. Devil's-advocate
  fork (general-purpose, fresh context, F-001/F-002/F-009 envelope,
  3 alternatives) output embedded verbatim in Alternatives
  considered; Alt B (finished-form-clean) selected. Landing gate
  narrated in ADR-0015 amendment 5 (ungated; `phase_at_least_14`
  guards the io stub swap only).
- 2026-05-29 (amendment 2): fn_val constant serialization. Step 0.6
  surfaced that the v2 serializer rejected `fn_val` constants, so
  `cljw build` could not serialize any program with `(defn …)` —
  a hollow v0.1.0 deliverable. Added "fn_val constant serialization"
  section (A2-D1..A2-D4): serialize fn constants by contents (slot_base
  + per-method arity/has_rest + recursive `serializeChunk` of the method
  body); `closure_bindings != null` is the only error (invariant guard,
  never a constant); deserialized fns are gpa+trackHeap with sub-chunks
  freed via `freeChunk` recursion (freeEnvelope-before-rt.deinit ordering
  documented), sentinel `body` Node with a tree_walk guard, param-name
  strings dropped (debug-only, D-139). Devil's-advocate fork
  (general-purpose, fresh context, F-002/F-004/F-009/F-010 envelope, 3
  alternatives) embedded verbatim; Alt B (finished-form-clean) selected.
  Closes the D-100(b) "serializer Discharged" overclaim — same
  claimed-done-but-incomplete pattern as the cycle-4 lazy fns this
  session.
