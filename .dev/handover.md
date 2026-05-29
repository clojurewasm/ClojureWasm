# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `e5a58552` (row 14.11 closed; see `git log` for exact HEAD —
  it advances each commit).
- **First commit on resume MUST be**: **row 14.13 — finish `compat_tiers`
  reconciliation, then bench/history + with-context.** Survey
  `private/notes/phase14-14.13-compat-tiers-survey.md`. DONE this session:
  math/spec down-tier from Tier A @57d4e3f9; edn/pprint/tools.cli/data.json/
  data.csv promoted from "planned" to verified-implemented @22624c40;
  metadata refresh. REMAINING compat_tiers: (a) the ~40 `native_ns:
  "cljw.host.java.*"` host_classes entries — **NOT a blanket sed**: the
  L103-107 comment says they migrate to `cljw_ns: "cljw.java.*"` (ADR-0029)
  **per-class as each host class lands**, so migrate only entries whose
  class is actually implemented; no tooling reads `native_ns` (doc-metadata
  only — G3 reads `keyword:`/`files:`); (b) `clojure.zip` Tier A→B
  precision (it's implemented, so a tier-label call, not a lie). Then row
  14.13 (2) `bench/history.yaml` v0.1.0 lock-point (ADR-0044) + (3)
  `cljw.error/with-context` macro (v5 §13.6). D-066 already Discharged; man
  page = D-119 (opportunistic).
- **Forbidden this session**: re-opening D-100 (a-e ALL discharged —
  `cljw build` ships end-to-end) or the lazy-seq cluster (ADR-0054
  complete). Widening wasm FFI / row 14.12 (zwasm-v2-gated, F-010
  de-prioritises it). Pulling the v0.1.0 tag (row 14.14) before 14.13
  lands. Making finite `(range n)` lazy (deferred — needs count/nth on
  lazy_seq; tracked DIVERGENCE). Chunking (ADR-0054 D5). Exact
  cross-category `==` / `compare` (D-014a ladder).

## Current state

Phase 14 v0.1.0 IN-PROGRESS. Mac gate **103/103** (read from the on-disk
log; ubuntunote re-verify at the next Phase boundary per ADR-0049).
**`cljw build` ships end-to-end** (D-100 (a)-(e) all discharged @e5a58552):
`cljw build app.clj -o app` compiles to a self-contained binary with a
`"CLJC"` trailer that re-runs its embedded bytecode at startup — including
user functions (fn_val serialization, ADR-0034 am2) and cross-chunk defs
(interleaved per-chunk startup run). The bootstrap setup is one shared
`bootstrap.setupCore` chain (F-009). ADR-0054 lazy-seq Layer-2 also
COMPLETE (row 14.13.5). Phase 14 remaining: 14.13 polish, 14.12 (deferred,
F-010), 14.14 release.

## Active task

**Row 14.13 — v0.1.0 polish bundle (in progress).** Landed this session:
compat_tiers math/spec down-tier + edn/pprint/tools.cli/data.json/csv
promote. Remaining (see Resume contract): compat_tiers `cljw.host.*`
per-class migration + `clojure.zip` tier precision; `bench/history.yaml`
v0.1.0 lock-point (ADR-0044); `cljw.error/with-context` macro. No code
blocker.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-119** `cljw` man-page rendering (deferred from D-066; opportunistic,
  no Clojure surface depends on it — row 14.13 may pick it up).
- **D-139** AOT-built fns drop param-name labels in error frames
  (ADR-0034 am2 A2-D3; opportunistic). **D-140** `cljw` startup reads the
  whole self-exe to check the trailer (footer-seek perf pass).
- **D-131** ADR-0034 deferred trailer blocks (bootstrap-cache / Tier-0 /
  build-id; post-v0.1.0). **D-103** bytecode-cache version scope includes
  the peephole rule set (now latent — D-100(b) shipped). **D-092**
  keyEq→valueEqual + structural valueHash. **D-135** bare `()`. **D-138**
  `e2e_phase14_error_format` flaky-once watch.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ ROADMAP §9.16 row 14.13 → `compat_tiers.yaml` + `.dev/debt.md` (D-066).
