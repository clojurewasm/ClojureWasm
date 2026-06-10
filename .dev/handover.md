# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (D-377 facet 2 / ADR-0129 just pushed atop the
  flatland.ordered convergence chain). Gate cadence (ADR-0107): per-commit
  **smoke** (`bash test/run_all.sh --smoke <step>`, background, don't block);
  **batch the full gate** at the ≤5 ceiling / boundary — run ALONE with
  `timeout 900 bash test/run_all.sh --serial-e2e` (the default `-P8` flakes +
  `run_gate.sh`'s `timeout 300` is too short for the 283-step e2e). Corpus is
  relational (never pin an absolute hash, AD-009). Probes on a ReleaseSafe binary.
- **First on resume MUST be: D-380 DC1** — the code/clj-driven categorised
  'differences from Clojure' doc (consolidate the AD ledger AD-001…028 +
  COVERAGE.md 'acceptable divergences' into ONE readable, category-organised
  human-facing doc; use `scripts/clj_diff_sweep.sh`; readable, NOT sprawl; never
  pin a JVM hash constant). Then DC2 (debt.yaml resolution-status re-org — move
  discharged rows, dedup) → DC3 (private/ CFP `_v2.md` refresh, only if time).
  Full barrier in `.dev/debt.yaml` D-380. NO code changes in this mode.
- **Forbidden**: pushing to `main`. The fly demos (D-362) are DONE + live.

## Just landed — D-377 facet 2 / ADR-0129 (deftype hasheq+equiv as a HAMT key)

- Revived the dormant `dispatch.current_env` (armed at `driver.evalForm` +
  `tree_walk.treeWalkCall`, the both-backend choke point) as the ambient eval Env.
- `equal.hashDispatch` (shared by the `(hash x)` primitive AND the HAMT key sites,
  F-011) + `hashConsult`/`eqConsult` dispatch a non-record deftype/reify's
  Object/hasheq | equiv|equals at the key-bucketing + within-bucket-compare sites;
  `@errorCast` narrows the dispatch `anyerror` at the consult boundary so
  map.assoc/get keep their error set (zero caller ripple).
- Fixed an orthogonal `collHash` bug surfaced here: `hash-unordered-coll`/
  `hash-ordered-coll` only walked a `.list`-tagged seq → a lazy/cons/deftype seq
  read as empty; now walks the general first/next seq (native values unchanged).
- Verified on flatland.ordered + ReleaseSafe: `(= om n)`, `(= (hash om)(hash n))`,
  `#{om n}`→1, `(contains? #{om} n)`→true; e2e phase14_deftype_key_hash green;
  smoke 5/5, corpus 2272/2272. DA fork reflected verbatim in ADR-0129.

## Follow-ups tracked

D-381 (lazy per-instance hasheq cache — ADR-0129 perf-defer, F-010 window) ·
D-380 (doc mode, next) · D-374 (top-level-`do` unroll) · D-376 (Murmur3/
hashUnencodedChars) · D-369 / D-238 / D-276. quality_floor rows = standing drain.
Per-task notes: `private/notes/D37{3,5,7}-*.md` + `D377-facet2-*.md`.

## Cold-start reading order

handover → `.dev/debt.yaml` D-380 (the doc-consolidation barrier — DC1/DC2/DC3) →
`.dev/accepted_divergences.yaml` + COVERAGE.md (DC1 inputs) → CLAUDE.md
§ Autonomous Workflow.
