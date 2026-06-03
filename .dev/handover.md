# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (Phase 15 / F-010 post-M quality loop on
  `cw-from-scratch`). Gate green 231/0 (Mac). debt ledger = `.dev/debt.yaml`.
- **First commit on resume MUST be**: continue the **D-232 validation campaign**
  (standing `quality-loop floor: validation-campaign`) — run the next upstream
  `clojure.test-clojure.<x>` suite through cljw, root-cause the first gap (F-011),
  big-bang per suite. Run via `cljw -cp ~/Documents/OSS/clojure/test -e '(require
  (quote clojure.test-clojure.<x>)) (clojure.test/run-tests …)'`. D-232's status
  field catalogs every parked finding + which suites now load.
- **Forbidden this session**: cold-seizing the structural-deferred units without
  their owner decision — **D-237** `with-local-vars` (anonymous-Var lifetime vs
  the GC membrane skipping `.var_ref` — resolve that FIRST), in-ns/use/refer as
  runtime fns (the test-helper-cluster blocker, DA-fork), Phase-15 concurrency
  (STM/agent/threading, DA-fork), `into-array`/Java arrays (F-004 slot),
  reflection (Field/Method). Also forbidden: "fixing" an AD-001..011 accepted
  divergence; widening the NaN-box inline int / adding an int slot (F-004 fixed);
  re-opening landed work (git log = SSOT); perf without a Release `scripts/perf.sh`
  number.

## Landed this session (git log = SSOT; one summary, not a log)

libspec `:only`/`:exclude` · `System/getProperty` · `set!` special form ·
`op_ctor_call` 8-bit name_idx overflow → `ctor_sites` side-table (D-233, was a
production-VM bug aborting whole `run-tests` batches) · `for` rewritten to clj's
`letfn`+`lazy-seq` `emit-bind` so `:while` works in every position incl.
post-`:when` (D-234) · `(:import …)` ns directive (D-235, simple-name class
resolution) · regex `\Q…\E` · the `.` interop special form (D-236) ·
`var-get`/`var-set` (D-237 parks `with-local-vars`). F-010 refactor-gate pass
(code-simplifier) over the stream: clean bar one redundant `catch`.

## D-232 validation campaign (standing quality-loop floor)

- **Now-loadable upstream suites** (after `:import`/`.`/`set!`/`\Q\E`): string.clj
  (49/51, parks on StringBuffer interop), for.clj (49/51, `(Integer. …)` ctor
  interop), data/parse/errors/api/clearing load past their `(:import …)`.
- **Parked findings (each a future unit, in `.dev/debt.yaml`)**: D-237
  with-local-vars (anonymous-Var/GC-membrane lifetime) · in-ns/use/refer runtime
  fns (test-helper cluster, 20 suites) · `into-array`/Java arrays (F-004) ·
  reflection (Field/Method) · `(Integer.)`/`(StringBuffer.)` JVM-ctor interop ·
  external-lib suites (test.check/data.generators/core.reducers — not loadable) ·
  keywords.clj 4 fails = error-message-format (accepted divergence).
- **Method discipline** (do not drift): `.claude/rules/clj_diff_sweep.md` — clj
  oracle, corpus-backed discharge, big-bang per suite, classify every DIFF as
  bug-fix or `AD-NNN` (`.dev/accepted_divergences.yaml`).

## clj-parity campaign (A-half) — COMPLETE; standing floor remains

- C1..C7 DISCHARGED (ADR-0076..0080). D-210 persists ONLY as the standing
  `quality-loop floor: clj-parity` — drain any NEW cljw↔clj DIFF a sweep surfaces.
- Decided, NOT bugs: AD-008 (Long overflow auto-promotes per F-005) · AD-009
  (cljw hash ≠ JVM) · D-211 (`+'`/`*'` deferred, F-005-inverted).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min; 1800 = headroom,
  the -P8 pool over-runs under load — memory `gate-parallel-e2e-timeout`). Never
  poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed ONLY via
  `scripts/perf.sh`. Edit/Write TRANSCODES literal non-ASCII (keep source ASCII;
  splice non-ASCII doc edits via python). Default backend is **VM** (build.zig
  `orelse .vm`, F-012); `evaluator.compare` cannot diff exprs routing through
  bootstrap `.clj` closures (for/concat/…) — use e2e + clj-oracle, not diff cases.

## Cold-start reading order (tracked-only)

handover → `.dev/decisions/0076_clj_parity_campaign_and_accepted_divergences.md`
+ ROADMAP §9.2.P → `.dev/accepted_divergences.yaml` +
`.claude/rules/accepted_divergences.md` → `test/diff/clj_corpus/COVERAGE.md` +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (D-232 campaign + D-237) →
CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/004/005/009/010/011/012) → `.dev/principle.md`.
