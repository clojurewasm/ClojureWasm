# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `e5a58552` (row 14.11 closed; see `git log` for exact HEAD —
  it advances each commit).
- **First commit on resume MUST be**: **row 14.13 — v0.1.0 polish bundle.**
  Remaining sub-deliverables (ROADMAP §9.16 row 14.13; **D-066 env var
  spec is already Discharged** — `docs/spec/error_format.md`; its man page
  is D-119, opportunistic): (1) `compat_tiers.yaml` Tier A/B declarations
  comprehensive review/finish; (2) `bench/history.yaml` v0.1.0 lock-point
  entry per ADR-0044 schema; (3) `cljw.error/with-context` macro (v5
  §13.6 user runtime error-injection API). Start with (1) compat_tiers
  review or (2) bench/history lock-point; Step 0 survey first.
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

**Row 14.13 — v0.1.0 polish bundle.** See Resume contract for the four
sub-deliverables. No code blocker; Step 0 survey then pick the first
sub-task (D-066 env var spec is the smallest entry).

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
