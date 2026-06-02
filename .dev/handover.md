# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (sweep + VM-parity commits on `cw-from-scratch`).
  Mac gate green (200).
- **First commit on resume MUST be: the next VM-default parity blocker**
  (F-012 / D-196, priority thread) — pick one of the 3 remaining via
  `scripts/check_vm_parity.sh`: (1) catch `:keyword` dispatch
  (`compiler.zig:360`, `op_match_type_keyword`), (2) `(ns …)`
  `:refer-clojure :exclude` + libspec (`compiler.zig:521`), (3)
  `.static_method` (`node.zig:338`). Each is a focused VM-backend cycle;
  ADR-0071 is the cleanup-handler precedent. Fallback standing mode if a
  blocker is wedged: continue the F-011 sweep (`scripts/clj_diff_sweep.sh`,
  COVERAGE.md § Next-sweep) into a `--corpus`.
- **Forbidden this session**: re-sweeping the COVERAGE.md § Swept areas
  wholesale; seizing the F-003 structural-deferred rows (D-164 empty≡nil,
  D-165 i48→i64, D-086/088/178/179) incrementally — those are big-bang,
  user-gated; re-opening landed work (git log = SSOT); JIT/superinstruction
  (post-M); re-opening perf without a Release `scripts/perf.sh` number.

## Operating mode — clj differential sweep (F-011) + quality-loop floor

Probe via BOTH `clj` (oracle) + `cljw`, fix at the finished form, commonise.
Autonomous; self-selects next area per F-002 / ROI. The harness is the SSOT —
do NOT hand-roll `for e in …; cljw vs clj` loops (rule Discipline 1). A
discharge that lists coverage MUST back it with corpus exprs (anti D-177
false-positive); `check_corpus_regression.sh` replays them cljw-only as a gate
step. Coverage is **big-bang, not drip-fed** (rule Discipline 2). **Check
F-NNN before "fixing"** — overflow auto-promote / `+'`-throws are intentional
(F-005); set print order + `(class 5)`→`Long` are acceptable (COVERAGE.md).

## Discharged this session (full rows in `.dev/debt.md`)

- **D-191** numeric constructors (bigdec/bigint full ctor parity) ·
  **D-194** bigdec arithmetic contagion (`+ - * / quot rem mod`) ·
  **D-182** JSON number parity (read number_string) ·
  **D-047** setString Linux bug → `big_int.parseBase10` consolidated fix
  (all 8 sites; ≥2^64 test restrictions removed) ·
  **D-177** corrected over-claimed discharge + landed 7 missing xform arities ·
  **D-193** folded into D-157 (add-watch is Phase-15, not a floor item).
- Plus drop-last/get-in arities, regex print, predicate cluster.
- **D-196 blocker (4) error-context — CLOSED (ADR-0071)**: VM distinguishes
  `.cleanup` from `.catch_clause` handlers (`op_push_cleanup`/`op_reraise`), so a
  `binding`/bare-try unwind preserves catalog Kind + dynamic error-context like
  TreeWalk's `defer`. 3 VM-default blockers remain (catch-keyword, ns-directive,
  static-dispatch). Plus even?/odd? BigInt + oversized-literal auto-promote;
  coerce_tower corpus.

## Remaining (pointers — full text in `.dev/debt.md` + COVERAGE.md)

- **Sweep next**: `test/diff/clj_corpus/COVERAGE.md` § Next-sweep candidates.
- **Structural-deferred (F-003, big-bang, user-gated)**: D-164 empty≡nil (the
  highest-leverage single fix — collapses a class of diffs), D-165 i48→i64,
  D-086/088/178/179, D-105 java.time.
- **v0.1.0 closeout**: Phase 14.14 — exit-smoke + `phase_at_least_14` flip +
  tag + **ubuntunote (Linux) gate** (ADR-0049). The D-047 fix unblocks ≥2^64
  on Linux.
- **Perf §9.2.S CLOSED** (Debug-measurement correction): O-001..O-004 landed;
  Release startup is ms (mission target met). Re-open ONLY with a Release
  `scripts/perf.sh` number proving a real regression. D-140 startup = moot.

## Process discipline (full detail in memory + rules)

- **Gate hazard**: the -P8 e2e pool intermittently times out under host load —
  use `timeout 1800 bash test/run_all.sh --serial-e2e` (memory
  `gate-parallel-e2e-timeout`). Mac per-commit; ubuntunote at Phase boundary.
- **Never poll a background gate**: launch `run_in_background`, yield, act on
  the completion notification, read once. **`clj -M -e` → `timeout 20`-wrap** +
  bound infinite seqs (`(take N …)`). **No `\a` char literals through `cljw -e`**
  (shell eats `\`); use a file / stdin heredoc.
- **Under host load, capture probe output to `/tmp/*.txt` and Read it** (bare
  reads garble). **Measure speed ONLY via `scripts/perf.sh`** (Release), NEVER
  `time zig-out/bin/cljw` (Debug) — `.claude/rules/perf_measure_release.md`.

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` (sweep state) +
`.claude/rules/clj_diff_sweep.md` (harness + disciplines) → `.dev/debt.md`
(open rows) → CLAUDE.md (§ Project spirit + Autonomous Workflow + The only
stop) → `.dev/project_facts.md` (F-002 / F-010 / F-011) → `.dev/principle.md`
(Bad Smell) → `.dev/reference_clones.md` (clj oracle). Optional scratch (if
present, NOT load-bearing): `private/notes/phaseA26-*.md`.
