# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `0ecba1d7` (clean tree, all pushed). D-144 landed 2026-05-29
  (ADR-0055 am2 doc `e8c15597` + source `0ecba1d7`) — see `git log`.
- **First commit on resume MUST be**: the **lazy-seq Layer-2 wiring** —
  the `.clj`-layer `lazy-seq` form + lazy `cons` so D-134's remaining
  **(b) lazy core fns** can be defined lazily: infinite `(range)` 0-arg
  + range step-arity + `repeat`/`repeatedly`/`iterate`/`cycle`/
  `take-while`/`drop-while`/`partition`. This is the foundational
  coverage floor (§A26 G9 + D-133) that §A26's cross-cutting ordering
  puts FIRST toward M ("finish G9/D-134 lazy + interop → Phase 15 →
  superinstruction → JIT → M"). A real structural dependency: Step 0
  survey `src/runtime/lazy_seq.zig` (Phase-5 force/first/rest) + cw v0
  lazy + JVM `clojure.lang.LazySeq`/`cons`; pick the Layer-2 shape
  deliberately (Devil's-advocate at depth ≥ 2).
- **Forbidden this session**: re-opening D-144 (DONE). Flipping
  `phase_at_least_14` / tagging v0.1.0 (release HELD by user). Treating
  §9.16 `[ ]` rows **14.12** (deferred, F-010) / **14.14** (release,
  held) as the next task. Bulk-adding eager Pattern-A core fns — D-134's
  eager (a) clusters are ALL DONE; only the (b) lazy forms remain. The
  interop prong (D-130 `.`/`new`/`set!`) comes AFTER the lazy cycle, not
  instead of it.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate **107/107**
green (`/tmp/gate_commit.log` @0ecba1d7). cw v1 ≈ 60-70% of cw v0's
surface in ~half the LOC; error UX — now incl. structured user-throw EDN
(`:kind :exception` + `:data` + `*error-context*`) — plus
`--compare`/`render-error` exceed v0. The F-010-ordered gaps (JIT /
nREPL-richness / line-editor / Wasm-Component / deps-test) stay deferred
per §A26.

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Per §A26 cross-cutting ordering: **finish G9/D-134 lazy + interop
coverage floor** (the next task) → **Phase 15** (concurrency: atom+watch,
STM, agent pools, future/promise, locking/volatile, pmap; unblocks D-117/
D-118 nREPL richness) → superinstruction/fusion → narrow ARM64 JIT
(D-133) → **M** → quality-elevation loop (`docs/works/`, G5/G7/G11).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-134** clojure.core coverage backlog — (b) lazy forms remain (next
  task's target). **D-130** interop `.`/`new`/`set!` (sibling prong,
  after lazy). **D-143** apply multi-arity spread. **D-142** Env-scope
  `*error-context*` (multi-Env nREPL). **D-141** bench multi-lock anchor.
  **D-105/D-106** time/net+crypto. **D-116** REPL line-editor. **D-117/
  D-118** nREPL richness (Phase-15-gated). **D-075** metadata (G4a
  `^:dynamic` cheap unblock). **D-133** JIT coverage-floor ordering.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `.dev/cw_v0_parity_and_gap_plan.md` §2 G9 + ordering note →
`.dev/debt.md` D-134 → `src/runtime/lazy_seq.zig` + `src/lang/clj/
clojure/core.clj` (the (b)-lazy + Layer-2 wiring site) → ROADMAP §9.17
(Phase 15 placeholder).
