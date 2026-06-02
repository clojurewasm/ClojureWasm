# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (clj-parity campaign COMPLETE on `cw-from-scratch`).
  Gate green (Mac). debt ledger = **`.dev/debt.yaml`**.
- **clj-parity campaign C1..C7 is COMPLETE** (ADR-0076 / §9.2.P; C7=D-165=
  ADR-0080, heap-boxed Long, landed this session). D-210 is now a STANDING
  `quality-loop floor: clj-parity` (drain any NEW sweep DIFF, no campaign units
  left). Loop is back in self-selected quality-floor-drain mode.
- **First commit on resume MUST be: D-213** (`(class e)` of ANY exception →
  "ex_info" not the specific class — `(class (ex-info "m" {}))`→cljw "ex_info"/
  clj "ExceptionInfo"; caught `(/ 1 0)`→cljw "ex_info"/clj "ArithmeticException").
  Fix: `protocol.zig::classPrim`'s `.ex_info` arm builds a `.type_descriptor`
  from the per-value `ExInfo.class_name` (ADR-0060; null→"ExceptionInfo") via a
  per-Runtime class-name→descriptor cache (simple name per AD-003). Then D-214
  (bit-ops on heap-Long operand raise — pre-existing i48-only gap). D-212
  (str/.toString numeric suffix) DONE this session. Full rows: `.dev/debt.yaml`.
- **Forbidden**: "fixing" an AD-001..009 accepted divergence (set print-order,
  `(class)` simple name AD-003, error Kind, **AD-008 Long-overflow auto-promote**,
  cljw hash AD-009 — see `.dev/accepted_divergences.yaml`); widening the NaN-box
  inline int or adding a new slot for an int representation (heap-Long is the
  `IntOrigin` flag on the heap-int, F-004 layout UNCHANGED); re-opening landed
  work (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Just landed (this session; git log = SSOT, full rows in `.dev/debt.yaml`)

- **C7 D-165 DISCHARGED** (ADR-0080, the LAST campaign unit): heap-boxed Long.
  An `IntOrigin = enum(u8){long,bigint}` flag on the heap-int struct (replaces
  one `_pad` byte — NO new NaN-box slot, F-004 UNCHANGED). A value in (2^47,i64]
  is now a Long (`(class)`→Long, print no `N`), promoting to BigInt only PAST
  i64. Classification by dispatch arm: alloc fns take a required `origin`;
  `promote.wrapManaged` range-splits, `wrapArith` propagates BigInt contagion
  (heap-Long operand on a Managed arm does NOT gain spurious N). `=`/`hash`
  untouched (value-equal across origins). Corpus `heap_long` (29); stale `…N`
  e2e updated to clj-correct. Spun off **D-214** (bit-ops on heap-Long, pre-
  existing i48-only gap). C1–C6 also DONE earlier this session (see git log).

## clj-parity campaign (A-half) — COMPLETE; standing floor remains

- **C1..C7 all DISCHARGED** (D-164/205/207/209/200/198/165; ADR-0076/77/78/79/80).
  D-210 persists ONLY as the standing `quality-loop floor: clj-parity` — drain
  any NEW cljw↔clj DIFF a future sweep surfaces (highest-value-first). No units left.
- **Open floor bugs (next drains)**: D-213 (class-of-exception) → D-214
  (bit-ops on heap-Long). D-212 (str-of-numeric suffix) DISCHARGED this session.
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
