# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (clj-parity campaign COMPLETE on `cw-from-scratch`).
  Gate green (Mac). debt ledger = **`.dev/debt.yaml`**.
- **clj-parity quality loop has CONVERGED** (campaign C1..C7 + 9 floor/sweep
  drains, all DISCHARGED this session: D-165/212/213/214/215/216/217/218/219/221).
  8 broad `clj_diff_sweep` probes → only AD-001..009 divergences + Phase-15
  structural gaps remain. D-210 is a STANDING `quality-loop floor: clj-parity`
  (drain any NEW sweep DIFF). Audit clean (private/audit-2026-06-03.md).
- **Phase 15 (concurrency) entered** — atom reference surface completed this
  session: **D-157 / ADR-0081** add-watch/remove-watch (appended `Atom.watches`,
  synchronous notify) + set-validator!/get-validator (appended `Atom.validator`,
  validate-before-commit → IllegalStateException, ref unchanged).
  delay/promise/future/atom/volatile already worked. Also landed: `pmap`/`pcalls`/
  `pvalues` (sequential, result-identical; parallelism deferred D-224) + `doall`/
  `dorun` + `alter-var-root` (var-root mutator, D-225). delay/promise/future/atom/
  volatile already worked.
- **Syntax-quote STAGE 1 LANDED (D-226 PARTIAL, ADR-0082)**: `` ` ``/`~`/`~@`/
  `foo#` work (non-qualifying); macros with backtick now run (single-ns +
  core-symbol). Key fix: `valueToForm` now FORCES lazy seqs (fixes all lazy
  macro expansions). **First action on resume — STAGE 2 = symbol QUALIFICATION**
  (`` `foo ``→`current-ns/foo`, `` `+ ``→`clojure.core/+`, + qualify emitted
  `seq`/`concat`/`list`): the analyzer expander (`syntax_quote.zig`) resolves each
  non-special/non-`~`/non-`foo#`/non-`.` symbol to its var's ns; this is the
  real-lib enabler (a macro referencing its own private helper needs it, D-158).
  Then nested-backtick depth + `macroexpand-1`. After: `with-redefs` (D-225) +
  clojure.test (D-227) become natural (their macros lean on backtick).
- **Phase-15 architectural pieces need a DA-fork entry** (do NOT cold-seize):
  `agent`, STM `dosync`/`ref` (§9 STM 15.1-15.4 ADR), `locking`, real threading
  (std.Io.Threaded work-pool — also activates real `pmap` parallelism D-224 +
  async `future` + 3-arg `deref` timeout). `*out*`/`with-out-str` + Java arrays
  = the system-var-registry + F-004 array-slot (tracked). Low-value: D-220
  (re-matcher), D-222 (bindable print vars), D-223 (atom kwargs).
- **Forbidden**: "fixing" an AD-001..009 accepted divergence (set print-order,
  `(class)` simple name AD-003, error Kind, **AD-008 Long-overflow auto-promote**,
  cljw hash AD-009 — see `.dev/accepted_divergences.yaml`); widening the NaN-box
  inline int or adding a new slot for an int representation (heap-Long is the
  `IntOrigin` flag on the heap-int, F-004 layout UNCHANGED); re-opening landed
  work (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Just landed (this session; git log = SSOT, full rows in `.dev/debt.yaml`)

- **Campaign C1..C7 + post-campaign floor drains** all landed this session
  (see git log). C7 D-165 (ADR-0080) = heap-boxed Long: an `IntOrigin` flag on
  the heap-int struct (NO new NaN-box slot, F-004 UNCHANGED); (2^47,i64] is a
  Long (class→Long, no `N`), BigInt only past i64; classification by dispatch
  arm + `wrapArith` BigInt contagion. Then the floor drains: D-212 (str/.toString
  drop N/M suffix), D-213 (`(class e)`→specific exception class via per-Runtime
  exceptionDescriptor cache), D-214 (bit-ops accept heap-Long via `expectI64`+
  `wrapI64`), D-216 (format surface), D-217 (string-Indexed), D-218 (peek/pop),
  D-219 (namespaced maps), D-221 (read-string `::`). Then the sweep CONVERGED
  (audit clean) and Phase 15 was entered: **D-157/ADR-0081 atom watches**
  (add-watch/remove-watch, synchronous notify, appended `Atom.watches` field).
  Each: own commit, corpus pin, e2e, full gate green.

## clj-parity campaign (A-half) — COMPLETE; standing floor remains

- **C1..C7 all DISCHARGED** (D-164/205/207/209/200/198/165; ADR-0076/77/78/79/80).
  D-210 persists ONLY as the standing `quality-loop floor: clj-parity` — drain
  any NEW cljw↔clj DIFF a future sweep surfaces (highest-value-first). No units left.
- **Open floor bugs (all LOW value, exploratory-found, both need infra)**: D-220
  (re-matcher/re-groups — needs a Matcher value type), D-222 (bindable print
  vars — needs var-read-from-primitive infra). This session DISCHARGED:
  D-212/213/214/215 + D-216 (format) + D-217 (string-Indexed) + D-218 (peek/pop)
  + D-219 (namespaced maps) + D-221 (read-string `::`) + D-157 (atom watches,
  Phase-15 piece). The clj-parity exploratory sweep has CONVERGED (8 broad probes
  → only AD-classified divergences + Phase-15-structural gaps remain). Next =
  Phase 15 concurrency (proper DA-fork entry for STM/agent/threading) OR the
  remaining low-value gaps D-220/D-222.
- **Decided, NOT bugs**: AD-008 (Long overflow past i64 auto-promotes per F-005;
  clj throws) · AD-009 (cljw hash ≠ JVM) · D-211 (`+'`/`*'` deferred, F-005-inverted).

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (~5min actual; 1800 is
  headroom — the -P8 pool over-runs under load, memory `gate-parallel-e2e-timeout`).
  Never poll a bg gate. `clj -M -e` → `timeout 20` + bound infinite seqs. Speed
  ONLY via `scripts/perf.sh`. Tool channel corrupts under host load — verify
  greps via Read / `bash grep`; and it TRANSCODES literal non-ASCII in
  Edit/Write (build expected non-ASCII via `printf` in tests, keep files ASCII).

## Cold-start reading order (tracked-only)

handover → `.dev/decisions/0076_clj_parity_campaign_and_accepted_divergences.md`
+ ROADMAP §9.2.P → `.dev/accepted_divergences.yaml` +
`.claude/rules/accepted_divergences.md` → `test/diff/clj_corpus/COVERAGE.md` +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.yaml` (D-210 standing floor /
open bugs D-212 + D-213 + D-214) + `.dev/decisions/0080_*` (C7 heap-Long) → CLAUDE.md
(§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/004/005/009/010/011/012) → `.dev/principle.md`.
