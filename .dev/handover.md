# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (≈ `6876aa8b`).
- **First commit on resume MUST be**: continue **ADR-0056 AOT-bootstrap**.
  Core is now AOT-restored from an embedded bytecode envelope on ALL
  startup paths (runner/repl/nrepl/built-apps). Two focused-context
  follow-ups remain, pick **Cycle 3** first (the edge win):
  **Cycle 3 — lazy non-core files**: the 11 non-core `.clj` (string/set/
  walk/zip/edn/json/csv/cli/pprint/test/cljw.error) still source-load
  eagerly in `bootstrap.loadCoreAot`; make them load on first `require`.
  Needs a per-file eager-vs-lazy dependency analysis first (survey §3.D3
  "hidden inter-namespace eager deps"; `cljw.error` is needed eagerly by
  `error_context.register`). **D-139 — AOT param-name fidelity**: deferred
  for memory-ownership care (normal fns borrow `params` from the analyzer
  arena; deserialized fns need owned strings; `freeFunction` can't
  distinguish → needs a params-ownership marker). Both are documented in
  ADR-0056 revision history + `private/notes/phaseA26-d-aot-bootstrap-cycles.md`.
- **Forbidden this session**: re-opening D-096 / the test-speed work /
  the macro batches / AOT Cycles 0-2 (all landed). Rushing D-139's
  param-ownership at session-tail (memory-bug risk — F-002). Dispatching
  a CPU-heavy subagent CONCURRENTLY with a gate (cold_start false fail).
  Flipping `phase_at_least_14` / tagging v0.1.0 (release HELD).

## Current state

Mac gate **125/125** green, **~80s** (was 390s: build-once + zone_check
pure-bash + ReleaseSafe e2e). **AOT-bootstrap LIVE** (ADR-0056): a build-
time `cache_gen` (build.zig) VM-compiles core.clj → an embedded bytecode
envelope; all startup paths `runEnvelope`-restore clojure.core instead of
parsing/analyzing/evaluating it (`bootstrap.setupCoreAot`/`loadCoreAot`,
`driver.runEnvelope`, Cycle-0 evalChunk hybrid). Gate-faithful. Edge/Wasm
per-instance cold-start is the win (native is OS-spawn-bound). **D-096
discharged** (shared `rt.stdout`; println works). 16 clojure.core macros
added this session (threading/conditional/iteration/case/condp).

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

AOT-bootstrap (edge-readiness) is the active user-directed thread. After
it: coverage floor (D-045 HAMT >8-key wall) → **Phase 15** concurrency
(ADRs 0009/0010) → superinstruction/fusion → narrow ARM64 JIT (D-133) →
**M** → quality loop. cw-v0 gaps in `.dev/cw_v0_parity_and_gap_plan.md`.

## Open debts (named; full rows in `.dev/debt.md`)

- **D-139** AOT param-name fidelity (focused cycle, memory-ownership).
  **D-131** built-app trailer (partially advanced — built apps AOT core
  now; non-core files + metadata blocks remain). **D-045** HAMT >8-key
  wall. **D-085** keyword-as-fn `(:k m)`. **D-134** residual macros
  (letfn/doseq/for — involved). **D-150** VM ctor parity. **D-153**
  `(cons x lazy)` count. **D-152** diff oracle `.clj` closures. **D-117/
  118** nREPL (Phase-15). **D-133** JIT floor. (D-076/D-096/D-130/D-136/
  D-137 discharged.)

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (F-010 + edge mission) →
`.dev/principle.md` → `.dev/decisions/0056_aot_bootstrap.md` (+ revision
history) → `private/notes/phaseA26-d-aot-bootstrap-cycles.md` →
`src/lang/bootstrap.zig` (setupCoreAot/loadCoreAot) + `src/eval/driver.zig`
(runEnvelope) + `build.zig` (cache_gen) → ROADMAP §1 (mission) + §A26.
