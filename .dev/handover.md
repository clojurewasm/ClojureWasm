# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `8edcc217` (ADR-0054 lazy-seq Layer-2 COMPLETE + cycle-3/4
  repair; see `git log` for exact HEAD — it advances each commit).
- **First commit on resume MUST be**: **row 14.11 — D-100 (b) step 2,
  `src/app/builder.zig`** (the `cljw build` CLI). Step 1 (payload
  envelope `serializeEnvelope`/`deserializeEnvelope`/`freeEnvelope` in
  `serialize.zig`, `[u32 n_chunks]` + per-chunk `[u32 len][bytes]`)
  landed (envelope in `serialize.zig`; see git log). D-100 (a) (full
  BytecodeChunk serializer) is ALREADY
  DISCHARGED @194eefaf — **do NOT re-implement (a) or the envelope.**
  Step 2 = new Layer-3 `builder.zig`: extract `runner.zig`'s `runSource`
  per-form compile-then-eval loop (@runner.zig:64-) into a neutral
  helper shared with the builder (F-009 mandatory), compile each form to
  a BytecodeChunk → `serializeEnvelope`, append a `"CLJC"` trailer
  (Deno-style), wire `build` into `cli.zig` dispatch, add an e2e test.
  (e) `cljw-formats/0.1.0.edn` archive lock follows. Design: ADR-0034
  am1 (Alt B) + ADR-0015 am5; survey
  `private/notes/phase14-14.11-survey.md`.
- **Resume disambiguation**: §9.16's numerically-first `[ ]` row IS
  14.11 (`[ ] partial` — (a)/(c)/(d) done, (b)/(e) outstanding) and it
  is now the resume target (lazy-seq row 14.13.5 closed). 14.12 is
  zwasm-v2-gated (defer per F-010). 14.13 polish + 14.14 release follow.
- **Forbidden this session**: re-opening D-126/D-127/D-134/D-136/D-137
  or lazy-seq cycles 1-4 (the whole cluster is discharged). Making
  finite `(range n)` lazy (deferred — needs count/nth on lazy_seq; a
  tracked DIVERGENCE in core.clj). Widening wasm FFI / row 14.12 (F-010
  de-prioritizes it). Pulling the v0.1.0 tag (row 14.14) before 14.11 +
  14.13 land. Chunking (defer per ADR-0054 D5). Exact cross-category
  `==` / `compare` (D-014a ladder).

## Current state

Phase 14 v0.1.0 IN-PROGRESS. Mac gate **102/102** (verified from the
on-disk log; ubuntunote re-verify at the next Phase boundary per
ADR-0049). **ADR-0054 lazy-seq Layer-2 is now COMPLETE** (all 4 cycles),
row 14.13.5 `[x]`:

- cycle 1 (e2e99de8): producer triad + `iterate`.
- cycle 2 (e14d024c): lazy map/filter/keep/remove + print realize.
- cycle 3 (8e0ce4db): lazy concat/mapcat/drop + infinite 0-arg `(range)`
  via `(iterate inc 0)` + lazy `=` force-walk in `equal.zig` (rt/env).
- cycle 4 + repair (8edcc217): lazy repeat/repeatedly/cycle/take-while/
  drop-while/partition. NOTE: 8e0ce4db/3661d7f5 shipped red during an
  infra-flakiness incident (range forward-ref to `iterate`; cycle-4
  fns missing); 8edcc217 repaired both — gate green again.

## Active task

**Row 14.11 — D-100 (b) step 3: `cljw build` CLI dispatch + trailer.**
Done: (b) step 1 payload envelope + step 2 compile-core
(`builder.zig::buildEnvelope`, unit-tested @b2d33f4f, gate 103). Step 3 =
wire `build` into `cli.zig` dispatch, read file → `buildEnvelope` →
Deno-style `"CLJC"` trailer → write binary; F-009-extract the shared
bootstrap setup (runner + builder); e2e test. Then (e)
`cljw-formats/0.1.0.edn` archive lock. F-009: the
per-form helper is shared by runner + builder, not duplicated.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-100** (b)/(e) outstanding (a/c/d done): (b) `cljw build`
  (`builder.zig` not yet written; payload envelope + per-form
  compile-then-eval + `"CLJC"` trailer; ADR-0034 am1 + ADR-0015 am5);
  (e) cljw-formats archive lock.
- **D-131** ADR-0034 deferred trailer blocks (post-v0.1.0). **D-103**
  bytecode-cache version scope must include peephole rule set (latent
  until D-100(b) ships). **D-092** keyEq→valueEqual + structural
  valueHash. **D-135** bare `()`. **D-138** `e2e_phase14_error_format`
  flaky-once watch.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ ADR-0034 (cljw build) + ADR-0015 am5 → ROADMAP §9.16 row 14.11 →
`.dev/debt.md` (D-100 / D-131 / D-103).
