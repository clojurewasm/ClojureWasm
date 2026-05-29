# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `28c54e26` (ADR-0054 cycle 4 landed → lazy-seq Layer-2
  COMPLETE, row 14.13.5 closed; see `git log` for exact HEAD).
- **First commit on resume MUST be**: **row 14.11 — D-100 (a)
  BytecodeChunk serializer**, the foundation the `cljw build` CLI (b)
  consumes. (a) = constants-pool serializer with NaN-box Value
  round-trip + `call_sites`/`libspecs` side-tables; design in ADR-0034
  am1 + ADR-0015 am5. Then (b) `cljw build app.clj -o app`
  (`src/app/builder.zig`, Deno-style binary trailer) and (e)
  `cljw-formats/0.1.0.edn` archive lock. Start with a failing
  round-trip test (serialize → deserialize a BytecodeChunk with a mix
  of int/string/keyword/collection constants). **ADR-0054 lazy-seq
  Layer-2 is DONE** (all 4 cycles), gate 102/102.
- **Resume disambiguation** (this `## Resume contract` overrides the
  ROADMAP §9.16 first-`[ ]` scan, per `handover_framing.md` "MUST be"):
  §9.16's numerically-first unchecked row is **14.11 (D-100 `cljw
  build`)** — and that IS now the resume target (the lazy-seq row
  14.13.5 closed). 14.11 is `[ ] partial`: (c)/(d) done, (a)/(b)/(e)
  outstanding. 14.12 is zwasm-v2-gated (defer per F-010). 14.13 polish
  + 14.14 release follow 14.11.
- **Forbidden this session**: re-opening D-126/D-127/D-134/D-136/D-137
  or lazy-seq cycles 1-4 (all discharged — the whole cluster is done).
  Making finite `(range n)` lazy (deferred — needs count/nth on
  lazy_seq; tracked DIVERGENCE in core.clj). Pulling the v0.1.0 tag
  (row 14.14) before 14.11 + 14.13 land. Chunking (defer per ADR-0054
  D5). Widening wasm FFI / 14.12 (F-010 de-prioritizes it). Exact
  cross-category `==` / `compare` (D-014a ladder).

## Current state

Phase 14 v0.1.0 IN-PROGRESS. Mac gate **102/102**; ubuntunote re-verify
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

**Row 14.11 — D-100 (a)/(b)/(e)** (BytecodeChunk serializer → `cljw
build` CLI → cljw-formats archive lock) — see Resume contract. The
lazy-seq Layer-2 row (14.13.5) is closed.

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
