# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (the flatland.ordered chain: D-373 instance?-fn / keyword-hash
  / D-375 hash statics / D-378 multi-pair assoc / D-379 java.util.Map methods / D-377
  facets `=`+map-hash, all pushed). Gate cadence (ADR-0107): per-commit **smoke**
  (`bash test/run_all.sh --smoke <step>`, background, don't block); **batch the full
  gate** at the ≤5 ceiling / boundary (run-alone, `--serial-e2e` — `run_gate.sh`'s
  `timeout 300` is too short for the full 283-step e2e). Manual probes on a
  **ReleaseSafe** binary; corpus is relational (never pins an absolute hash, AD-009).
- **First on resume MUST be: confirm direction** — the ordered.map LOAD chain is
  CLEARED (it loads + works + `(= om native)` + native-map-hash-consistent). The one
  remaining gap is **D-377 facet 2**: `(hash deftype-inst)` doesn't consult the
  deftype's hasheq impl — STRUCTURALLY blocked (`equal.valueHash` is rt-free, can't
  reach the vtable; needs a vtable hook in valueHash + the map-KEY hash path to use
  it too). A careful core-hash-path unit. If the human says continue, that or the next
  data-structure lib in the cluster (finger-tree / core.cache / rrb-vector / avl /
  priority-map / int-map / gvec — D-372/D-375/D-379 unlocked them).
- **Forbidden**: pushing to `main`. The fly demos (D-362) are DONE + live.

## Just landed (the flatland.ordered convergence chain)

- **D-373 / ADR-0128** — instance? is a fn over a class VALUE (higher-order works).
- **keyword-hash** determinism (valueHash had no `.keyword` arm → pointer hash).
- **D-375 / ADR-0108 am1** — APersistentMap/APersistentSet/Murmur3 static hash helpers.
- **D-378** — multi-pair assoc folds over pairs on an Associative deftype.
- **D-379** — java.util.Map/Map.Entry read methods (.get/.getKey/.val/…) on native colls.
- **D-377 facet `=`** — cross-type `=` consults a deftype's equiv (LEFT-operand, clj-exact);
  **facet 1** — a map's content hash folds the per-entry MapEntry hash, so
  `(hash m)` == `(hash-unordered-coll m)` (clj parity; all map hash values changed).
- **Gate-cadence scaffolding** reconciled to ADR-0107 (earlier this session).
- **Result: `(flatland.ordered.map/ordered-map …)` LOADS, preserves order, and
  assoc/dissoc/conj/into/get/seq/vals/keys + `(= om native)` all work.**

## Follow-ups tracked

D-377 facet 2 (deftype `(hash)` → hasheq; structural rt-free-valueHash) · D-374
(top-level-`do` unroll) · D-376 (Murmur3/hashUnencodedChars) · D-369 / D-238 / D-276.
quality_floor rows = standing drain. Per-task notes: `private/notes/D37{3,5}-*.md`.

## Cold-start reading order

handover → `.dev/debt.yaml` D-377 (facet 2 + the structural note) → the cluster libs →
CLAUDE.md § Autonomous Workflow.

## Stopped — user requested

User instruction (2026-06-10): 「チェーンをおってください」 (follow the flatland.ordered
blocker chain). Followed to completion of the LOAD chain — ordered.map loads + works +
`(= om native)` + native-map-hash-consistency, across 6 units (instance?-fn, keyword
hash, D-375/378/379, D-377 `=`+map-hash). The remaining `(hash om)`==native gap
(D-377 facet 2) is structurally blocked (rt-free valueHash) — a careful core-hash unit.
Checkpoint: confirm whether to take facet 2 (structural) or move to the next
data-structure lib in the cluster.
