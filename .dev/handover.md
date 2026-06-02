# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (VM-default flip + F-011 sweep + moderate-feature
  commits on `cw-from-scratch`). Gate green on `vm` (production default, flipped
  2026-06-02; ADR-0070 / F-012 realised): Mac 200, **ubuntunote Linux x86_64
  199** (1-PASS delta = Mac-only zlinter skip). F-012 cross-platform confirmed.
- **First commit on resume MUST be: a tracked MODERATE-FEATURE gap** —
  self-select per F-002 (highest real-code value first). The F-011 grab-bag
  quick-win phase is EXHAUSTED (recent ~6 sweeps were ~20/20 parity); the
  remaining work is focused analyzer/dual-backend features, each with a
  step-by-step discharge plan + `file:line` refs in its `.dev/debt.md` row.
  Recommended order:
  1. **D-202(1) — defrecord/deftype bare-field refs in protocol method
     bodies** (HIGHEST real-code frequency; wrap method bodies with a
     field-`let*` in `macro_transforms.zig::lowerDefType` — concrete plan in
     the D-202 row).
  2. **D-201 — `letfn`** (`letfn*` mutual-recursion special form + dual-backend).
  3. **D-202(2) — `extend-type` on a java class** (resolveJavaSurface target).
  4. **D-200 — EDN `#uuid`/`#inst` tagged literals** (reader infra; `#uuid`
     needs a UUID-type ADR — partial-string-parity vs a real type).
  **Verify moderate-feature work via e2e** (top-level forms) — `clj_diff_sweep`
  can NOT batch-verify define-heavy poly/reader forms (wraps each line in
  `(prn …)`; clj needs them top-level → `<clj-missing>`; see D-202 HARNESS
  NOTE). The standing F-011 sweep is a FALLBACK only. Other tracked follow-ups:
  (a) repurpose `check_vm_parity.sh` to run e2e on the non-default (tree-walk)
  backend; (b) v0.1.0-tag closeout (Phase 14.14).
- **Forbidden**: re-sweeping COVERAGE.md § Swept areas wholesale; seizing the
  F-003 structural-deferred rows (D-164 empty≡nil, D-165 i48→i64, D-086/088/
  178/179) incrementally — big-bang, user-gated; re-opening landed work
  (git log = SSOT); perf without a Release `scripts/perf.sh` number.

## Stopped — user requested

User instruction (2026-06-02): the F-011 quick-wins are done for this session;
the remaining moderate features are **NOT** permanently skipped — take them on
in a fresh, focused session. "Audit the wiring / reference chain so the next
clean session can autonomously decide + execute, then stop." Wiring audited +
set: this Resume contract repoints to the moderate-feature queue (D-202(1)
first); `.dev/debt.md` D-200 / D-201 / D-202 carry step-by-step discharge plans
+ `file:line` refs + the harness note; COVERAGE.md § Next-sweep lists them; the
cold-start reading order is intact. **Resume**: the next `/continue`
self-selects a moderate feature (D-202(1) recommended) — this stop does not
carry across sessions (CLAUDE.md § The only stop).

## Discharged this session (git log = SSOT; full rows in `.dev/debt.md`)

- **F-012 realised**: D-196 all 5 VM-parity blockers closed → `build.zig`
  default flipped to `vm` (ADR-0070 / ADR-0071 cleanup-handler kind,
  op_match_type_keyword, shared constructInstance, op_ns_with_filter);
  check_vm_parity = 0, Mac 200 + Linux 199.
- **D-199** transient read-ops · **D-198** PARTIAL (`.getMessage`/`.getCause`/
  `.getData`) · **D-202(3)** defmulti `:default`. Quick-wins: even?/odd? BigInt,
  oversized-literal auto-promote, `%b`/`%c`/`%N$` format, re-quote-replacement,
  print-str, namespaced `:keys`, force/delay?, realized?-on-lazy-seq.
- **~14 regression corpora** added (numeric/transients/threading/format/print/
  sorted/control-flow/destructuring/bit-math/coll-path/lazy-eval/str-char) —
  broad common-surface parity is corpus-backed.

## Remaining (pointers — full text in `.dev/debt.md` + COVERAGE.md)

- **Moderate features**: D-202(1)/(2), D-201, D-200 (see Resume contract).
- **Structural-deferred (F-003, big-bang, user-gated)**: D-164 empty≡nil
  (highest-leverage single fix), D-165 i48→i64, D-086/088/178/179, D-105.
- **v0.1.0 closeout**: Phase 14.14 — exit-smoke + `phase_at_least_14` flip +
  tag (D-047 unblocks ≥2^64 on Linux).
- **Perf §9.2.S CLOSED**: Release startup is ms; re-open ONLY with a Release
  `scripts/perf.sh` regression number. D-140 startup = moot.

## Process discipline (SSOT = memory + rules; do NOT re-expand here)

- Gate: `timeout 1800 bash test/run_all.sh --serial-e2e` (the -P8 pool times
  out under load — memory `gate-parallel-e2e-timeout`). Never poll a bg gate.
  `clj -M -e` → `timeout 20`-wrap + bound infinite seqs. Speed ONLY via
  `scripts/perf.sh` (Release) — `.claude/rules/perf_measure_release.md`.

## Cold-start reading order (tracked-only)

handover → `test/diff/clj_corpus/COVERAGE.md` (sweep state) +
`.claude/rules/clj_diff_sweep.md` → `.dev/debt.md` (open rows: D-200/201/202)
→ CLAUDE.md (§ Project spirit + Autonomous Workflow + The only stop) →
`.dev/project_facts.md` (F-002/010/011/012) → `.dev/principle.md` (Bad Smell).
