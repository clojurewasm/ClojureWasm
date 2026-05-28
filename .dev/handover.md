# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `e2e99de8` (lazy-seq producer wired; see `git log` for
  exact HEAD — it advances each commit).
- **First commit on resume MUST be**: **ADR-0054 cycle 3** — convert
  `concat` / `mapcat` / `drop` to lazy `.clj`; add the infinite 0-arg
  `(range)` (lazy); and **lazy `=`** — `runtime/equal.zig`'s sequential
  arm walks only vector/list today, so `(= (map inc [1 2]) '(2 3))`
  must force-walk `.lazy_seq`. NOTE: `valueEqual(rt,a,b)` takes `rt`
  but not `env`; forcing a lazy seq needs `env` — so cycle 3 threads
  `env` into `valueEqual` + the `=` primitive call (a smaller sibling
  of cycle 2's print-`rt/env` ripple). Then cycle 4: repeat/repeatedly/
  cycle/take-while/drop-while/partition.
  **Cycle 1 (producer) + cycle 2 (lazy map/filter/keep/remove + print
  realize + 2 seq-protocol root-cause fixes) are DONE** (gate 100/100).
- **Resume disambiguation** (this `## Resume contract` overrides the
  ROADMAP §9.16 first-`[ ]` scan, per `handover_framing.md` "MUST be"):
  §9.16's numerically-first unchecked row is **14.11 (D-100 `cljw
  build`)** — that is NOT the immediate next task. The chosen next is
  **ADR-0054 cycle 3 (row 14.13.5)**. D-100(b)/(e), 14.12, 14.13 remain
  pending v0.1.0 work but are not the resume target; do cycle 3 first.
- **Forbidden this session**: re-opening D-126/D-127/D-134/D-136/D-137
  or lazy-seq cycle 1 (all discharged). Pulling the v0.1.0 tag (row
  14.14) before lazy-seq (row 14.13.5) + the rest of the 14.13 bundle
  land. Chunking (defer per ADR-0054 D5). Exact cross-category `==` /
  `compare` (D-014a ladder).

## Current state

Phase 14 v0.1.0 IN-PROGRESS. Mac gate **100/100**; ubuntunote re-verify
at the next Phase boundary (ADR-0049). This session re-cut the interim
goal + drove a large clojure.core coverage + correctness pass:

- **F-010 + ADR-0051** (interim-goal re-cut): milestone M = Phase 15 +
  cw-v0-level JIT, then a quality-elevation loop; wasm-FFI breadth
  re-sequenced (F-001 not superseded). `clojure-corpus` +
  `clojuredocs-export-edn` wired in `reference_clones.md`.
- **Two foundational correctness fixes** (both were numeric-only bugs):
  **ADR-0052** universal `=` (`runtime/equal.zig`) + `==`; **ADR-0053**
  general 3-way `compare` (`runtime/compare.zig`).
- **clojure.core coverage** (D-126/127/134 clusters): get-in/assoc-in/
  update-in/update/concat/mapcat/vec/mapv/filterv/reverse/last/reduce-kv/
  update-keys/update-vals/not-any?/butlast/dedupe/distinct/frequencies/
  group-by/empty?/interpose/fnil/zipmap/interleave/max-key/min-key/
  flatten/reductions/second/ffirst/not-empty/take-last/drop-last/sort/
  sort-by/range(finite)/map-indexed/keep-indexed + pr-str/prn/print.
- **ADR-0054 lazy-seq Layer-2 cycle 1**: producer wired (`lazy-seq`
  macro + `__lazy-seq-create` + `iterate`); `(take 5 (iterate inc 0))`
  → `(0 1 2 3 4)` — the never-met Phase-6 exit criterion now holds.

## Active task

**ADR-0054 cycle 2** (row 14.13.5) — see Resume contract. Then cycle 3
(concat/mapcat/drop lazy + infinite range + lazy `=` in `equal.zig`)
and cycle 4 (repeat/repeatedly/cycle/take-while/drop-while/partition).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-100** (b)/(e): `cljw build` CLI (designed — ADR-0034 am1 +
  ADR-0015 am5; payload = sequence-of-chunks + per-form compile-then-eval;
  `src/app/builder.zig` not yet written) / cljw-formats archive lock.
- **D-138** watch: `e2e_phase14_error_format` flaky once in the gate
  (passed standalone + on re-run) — re-run, not a regression.
- **D-092** keyEq→valueEqual + structural valueHash (collection map/set
  keys). **D-131** ADR-0034 deferred build blocks. **D-135** bare `()`.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ ADR-0054 (lazy-seq phasing) → ROADMAP §9.16 row 14.13.5 →
`.dev/debt.md` (D-100 / D-092 / D-134 lazy cluster).
