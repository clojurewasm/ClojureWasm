# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (the flatland.ordered convergence chain: D-373 instance?-fn /
  keyword-hash / D-375 hash statics / D-378 multi-pair assoc / D-379 java.util.Map
  methods / D-377 `=`+map-hash facets, all pushed). Gate cadence (ADR-0107): per-commit
  **smoke** (`bash test/run_all.sh --smoke <step>`, background, don't block); **batch
  the full gate** at the ≤5 ceiling / boundary — run ALONE with `--serial-e2e` (the
  default `-P8` flakes + `run_gate.sh`'s `timeout 300` is too short for the 283-step
  e2e; run `timeout 900 bash test/run_all.sh --serial-e2e`). Corpus is relational
  (never pin an absolute hash, AD-009). Manual probes on a ReleaseSafe binary.
- **First on resume MUST be: D-377 facet 2** (`(hash deftype-inst)` consult its hasheq
  impl). USER DIRECTIVE (2026-06-10): take it **あるべき論 — wide blast radius is OK,
  but NO ad-hoc**; it is a proper fix of cljw's hash architecture (rt-free
  `equal.valueHash` can't reach the vtable; finished-form sketch + the measured
  `=`/hash contract violation it closes are in `.dev/debt.yaml` D-377 barrier).
- **THEN (self-continuing): D-380 doc-consolidation mode** (NO code): DC1 categorised
  'differences from Clojure' doc (code/clj-driven, consolidate the AD ledger — readable,
  not sprawl) → DC2 debt.yaml resolution-status re-org (move discharged rows, dedup) →
  DC3 (time-permitting) private/ CFP `_v2.md` refresh (keep originals, latest-only).
  Full barrier in `.dev/debt.yaml` D-380.
- **Forbidden**: pushing to `main`. The fly demos (D-362) are DONE + live.

## Just landed (the flatland.ordered convergence chain — LOAD chain CLEARED)

- **D-373 / ADR-0128** — instance? is a fn over a class VALUE (higher-order works).
- **keyword-hash** determinism (valueHash had no `.keyword` arm → pointer hash).
- **D-375 / ADR-0108 am1** — APersistentMap/APersistentSet/Murmur3 static hash helpers.
- **D-378** — multi-pair assoc folds over pairs on an Associative deftype.
- **D-379** — java.util.Map/Map.Entry read methods (.get/.getKey/.val/…) on native colls.
- **D-377 `=` facet** — cross-type `=` consults a deftype's equiv (LEFT-operand, clj-exact);
  **facet 1** — a map's content hash folds the per-entry MapEntry hash → `(hash m)` ==
  `(hash-unordered-coll m)` (clj parity; all map hash values changed, corpus relational held).
- **Result**: `(flatland.ordered.map/ordered-map …)` LOADS, preserves order, and
  assoc/dissoc/conj/into/get/seq/vals/keys + `(= om native)` all work. ordered-set loads.
  Audit (this session close): debt refs all resolve; 28 ADs pinned+in-sync; rows accurate.

## Follow-ups tracked

D-377 facet 2 (deftype `(hash)` → hasheq; the `=`/hash contract gap) · D-380 (doc mode) ·
D-374 (top-level-`do` unroll) · D-376 (Murmur3/hashUnencodedChars) · D-369 / D-238 / D-276.
quality_floor rows = standing drain. Per-task notes: `private/notes/D37{3,5,7}-*.md`.

## Cold-start reading order

handover → `.dev/debt.yaml` D-377 (facet 2 barrier — the あるべき論 directive + finished
form) → D-380 (the doc mode that follows) → CLAUDE.md § Autonomous Workflow.

## Stopped — user requested

User instruction (2026-06-10): leave D-377 facet 2 for the NEXT clear session and do it
あるべき論 (wide blast OK, no ad-hoc); then wire a SELF-CONTINUING doc-consolidation
mode (consolidate/modernise, don't sprawl): a code/clj-driven categorised
differences-from-Clojure doc + a no-code debt-resolution-status re-org; CFP `_v2.md`
drafts under private/ only if time (CFP prep is otherwise ~done). Then audit the wiring +
reference chain and stop. → Wired into D-377 (facet 2 directive + finished form) + D-380
(the doc mode) + this contract. Reference-chain audit done + clean. The next `/continue`
starts at D-377 facet 2.
