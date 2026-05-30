# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (≈ `b852ac59`).
- **Direction (user, 2026-05-30)**: raise **functional completeness FIRST**,
  before optimization complexity (no premature JIT/superinstruction). Work
  **corpus-driven**, not AI-probed. Keep strong cross-session state. Clone /
  copy liberally. Fully autonomous; flexible replanning encouraged.
- **First task on resume**: continue the **core-coverage gap sweep** driven
  by [`.dev/core_coverage_gaps.md`](core_coverage_gaps.md) (the unbiased
  real-`clojure.core`-vs-cljw diff, ~355 missing, triaged). Work the **P0
  batch first** — `hash` (expose `equal.valueHash`), `gensym` (expose
  `rt.gensym`), `volatile!`/`vreset!`/`vswap!`/`volatile?` (mutable box,
  mirror `runtime/atom.zig`), `comparator` (core.clj), `bigint`/`bigdec`
  (wrap existing numeric) — additive, batch the gate (cadence ≤5). Then P1
  (memoize / sorted-map+set / metadata / transducers) → P2 (isa?/hierarchy,
  resolve/ns introspection). **letfn** still queued (surveyed:
  `private/notes/phaseA26-letfn-survey.md`). Always confirm a gap with a
  `cljw -e` probe before implementing (static map has minor false-positives,
  e.g. `subvec` works). Do NOT ask (Direction-ask smell).
- **Forbidden this session**: re-opening anything landed this session
  (ratio arithmetic, **D-045** HAMT, **D-085** keyword/data-as-IFn, **atoms**)
  or earlier (AOT, format, doseq/for, numeric-coercion batch). Optimization
  work (JIT / superinstruction) — functional completeness first per user.
  `AskUserQuestion` to pick the next task. CPU-heavy subagent during a gate.
  Flipping `phase_at_least_14` / tagging v0.1.0 (release HELD).

## Current state

Mac gate **157/157** green, **~50s** (parallel e2e pool, `-P8`, `wait -n`;
`SERIAL_STEPS` serial). Gate cadence mechanically enforced (additive batches
≤5; shared-code gates every time; `.dev/.gate_pass` content-hash). AOT-
bootstrap LIVE (ADR-0056). Landed this session (git log is the SSOT):
**ratio arithmetic** (`+ - * /` over ratio / mixed / float, collapse-to-Long),
**D-045 HAMT** (maps/sets > 8 entries fully work — build/read/assoc/dissoc/
keys/vals/seq/print/=; residuals D-155 collision-bucket + D-156 dissoc
inline-collapse), **D-085 keyword/data-as-IFn** (`(:k m)`/`(m k)`/`(#{} x)`/
`([v] i)` + `(map :k coll)` + `(-> m :k)` — one chokepoint `treeWalkCall` +
Layer-0 `lookup.zig`). Verified working: destructuring, cond->/as->, threading,
cond/case/condp, assoc-in/get-in/update-in.

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

AOT-bootstrap done. Coverage floor heavily advanced (ratio-arith, HAMT,
keyword/data-as-IFn all landed). Remaining toward M: atoms/letfn →
**Phase 15** concurrency (ADRs 0009/0010 — atoms pull-forward decision lives
here) → superinstruction/fusion → narrow ARM64 JIT (D-133) → **M** → quality
loop. cw-v0 gaps in `.dev/cw_v0_parity_and_gap_plan.md`.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-139** AOT param-name fidelity. **D-134** letfn + re-seq +
  mapcat-multi-coll residuals (ratio-arith/format/doseq/for/coercions done).
  **D-155** HAMT collision bucket (rare). **D-156** HAMT dissoc inline-collapse
  (micro-opt). **D-150** VM ctor parity. **D-153** `(cons x lazy)` count.
  **D-152** diff oracle `.clj` closures (Fixture has no core.clj — keep diff
  cases primitive-only). **D-131** built-app non-core files. **D-117/118**
  nREPL (Phase-15). **D-133** JIT floor. (D-045/D-076/D-085/D-096/D-130/D-136/
  D-137/D-154 discharged.)
- **New gaps found 2026-05-30** (not yet D-rows): **atoms** absent (`atom`/
  `swap!`/`reset!`/`@` → name_error) = next unit; **defrecord** keyword field
  access returns nil (`(:x (->P 1 2))` → nil) — Phase-7 follow-up.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The only
stop) → `.dev/project_facts.md` (F-010 + edge mission) → `.dev/principle.md`
→ `.dev/decisions/0056_aot_bootstrap.md` (+ revision history) →
`private/notes/phaseA26-*.md` → `src/lang/bootstrap.zig` +
`src/eval/driver.zig` + `build.zig` (AOT) → ROADMAP §1 (mission) + §A26.
