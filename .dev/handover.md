# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `0bb7e89c` (clean tree, all pushed). D-144 (user-throw EDN)
  + D-134 (b) range 3-arg landed 2026-05-29 — see `git log`.
- **First commit on resume MUST be**: **D-145 — the `fn` macro**
  (survey-first cycle). `(fn [x] …)` is unresolved today: only the
  `fn*` special form exists; `defn` + core.clj use `fn*` internally,
  but real Clojure corpus uses `(fn …)` pervasively, so this is a
  coverage-floor blocker (D-133 / F-010 quality loop) — higher leverage
  than any single clojure.core fn. **Step 0 survey** (mandatory):
  JVM `clojure.core/fn` macro shape (self-name / multi-arity dispatch /
  destructuring / pre-post), a cw `fn*` capability audit (does `fn*`
  already do multi-arity? is destructuring landed?), and whether `fn`
  should be a bootstrap macro in core.clj or an analyzer transform.
  Land the common no-destructure case forwarding to `fn*` first; pick
  the shape deliberately (Devil's-advocate at depth ≥ 2).
- **Forbidden this session**: re-opening D-144 / range 3-arg (DONE).
  Re-attempting "lazy-seq Layer-2 wiring" as a task — it was ALREADY
  closed (ADR-0054 / `ec9ccfed`); D-134 (b) lazy forms are ALL done
  (Step 0.6 corrected the stale framing). Flipping `phase_at_least_14` /
  tagging v0.1.0 (release HELD by user). Treating §9.16 `[ ]` rows
  **14.12** (deferred, F-010) / **14.14** (release, held) as the next
  task.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate **107/107**
green (`/tmp/gate_range.log` @0bb7e89c). cw v1 ≈ 60-70% of cw v0's
surface in ~half the LOC; error UX (incl. structured user-throw EDN +
`*error-context*`) + `--compare`/`render-error` exceed v0. The
F-010-ordered gaps (JIT / nREPL-richness / line-editor / Wasm-Component /
deps-test) stay deferred per §A26.

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

Per §A26 cross-cutting ordering, finish the **coverage floor** first:
D-145 (`fn` macro, next) → D-146 (`#()` reader macro) → interop
`.`/`new`/`set!` (D-130) → **Phase 15** (concurrency; unblocks D-117/
D-118 nREPL richness) → superinstruction/fusion → narrow ARM64 JIT
(D-133) → **M** → quality-elevation loop (`docs/works/`, G5/G7/G11).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-145** `fn` macro (next task — coverage-floor blocker). **D-146**
  `#()` reader macro. **D-130** interop `.`/`new`/`set!`. **D-134**
  clojure.core backlog — (b) lazy ALL done; only `partition` 4-arg pad +
  JVM step-0 nicety remain. **D-143** apply multi-arity spread. **D-142**
  Env-scope `*error-context*` (multi-Env nREPL). **D-141** bench
  multi-lock anchor. **D-105/D-106** time/net+crypto. **D-116** REPL
  line-editor. **D-117/D-118** nREPL richness (Phase-15-gated). **D-075**
  metadata (G4a `^:dynamic`). **D-133** JIT coverage-floor ordering.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `.dev/cw_v0_parity_and_gap_plan.md` §2 + ordering note → `.dev/debt.md`
D-145 → `src/lang/clj/clojure/core.clj` (`fn*` usage + bootstrap macros)
+ `~/Documents/OSS/clojure/src/clj/clojure/core.clj` (`fn` macro) →
ROADMAP §9.17 (Phase 15 placeholder).
