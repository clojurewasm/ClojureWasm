# ADR-0107 — Two-tier gate: smoke-authorized per-commit + batched run-alone full gate

- Status: Proposed → Accepted (2026-06-07)
- Supersedes the per-commit cadence half of `.claude/rules/gate_cadence.md`
  (which remains the SSOT once rewritten — see § Rule edit).
- Related: ADR-0005 / ADR-0036 (dual-backend differential oracle), ADR-0024
  (run_all dispatcher), ADR-0049 (orphan/fan hazard), F-002 / F-012; the
  `gate_parallel_e2e_timeout` + `premature_gate_notification` memories.

## Context

The full Mac gate (`bash test/run_all.sh --serial-e2e`, ~5 min) became the
per-iteration wall-clock bottleneck. The user asked for a way to **develop while
gates queue** (true dev∥gate concurrency).

A Devil's-advocate fork (fresh context) found the concurrency premise **unsafe**,
and that the gate's cost/risk axis is **unit-vs-e2e, not correctness-vs-perf**:

- **`zig build test` (both backends) IS the entire F-012 correctness guarantee.**
  `src/lang/diff_test.zig` (the dual-backend differential oracle) is `@import`ed
  from `src/main.zig`, so every diff case runs inside `zig build test` — which is
  timing-independent, contention-tolerant, and fast-ish (two test exes).
- **The 248 e2e shell steps are ~60% of wall-time** and the only part that flakes
  under load (`gate_parallel_e2e_timeout`: the -P8 pool blew past 1200 s with NO
  concurrent dev; concurrent `zig build` worsens it AND contends the shared
  `zig-out/bin/cljw`, the reason `SERIAL_STEPS` exists). Running e2e concurrently
  with dev is unsafe, not just slow.
- **Perf/bench steps** (cold_start_threshold, exit_smoke, bench) false-fail under
  contention — a boundary/tag ritual, not a per-commit cost.

So the honest win is **iteration decoupling**, NOT concurrency: shrink the
per-commit check to the fast contention-tolerant core, and move the slow+flaky
e2e shell suite to a batched, run-alone gate.

## Decision (Alt B — the DA's recommendation)

A **two-tier gate split on the unit-vs-e2e axis**:

1. **`run_all.sh --smoke` = the per-commit check (~fast, target ≤ 60 s).** Runs
   the contention-tolerant correctness core:
   - `zig build test` on BOTH backends (vm + tree_walk) — the **full** F-012 diff
     oracle + every unit test (NOT a subset; a subset would weaken the oracle for
     no speed gain),
   - `zlinter` (Mac, catches deprecated-API rot),
   - `build_cljw` (a broken release build must never batch),
   - `corpus_regression` (cljw-only clj-parity replay, no network, fast),
   - PLUS the changed/new e2e step(s) for the unit at hand (passed to `--smoke`).
   On full success it stamps `.dev/.smoke_pass` with the
   `scripts/gate_state_hash.sh` content fingerprint.

2. **`run_all.sh` (full, unchanged) = the batched gate.** Adds the 248 e2e shell
   steps + perf/bench. Stamps `.dev/.gate_pass` as today. **Run ALONE** (no
   concurrent dev), `--serial-e2e` for determinism (or default -P8 only on a
   confirmed-quiet machine).

3. **Per-commit authorization.** A source-bearing commit is authorized by EITHER
   a fresh `.dev/.gate_pass` (full, today's rule) OR a fresh `.dev/.smoke_pass`
   (smoke-green for THIS exact content). `scripts/check_gate_cadence.sh` accepts
   both fingerprints.

4. **One batch ceiling, no other counters.** A single `.dev/.gate_cadence`
   counter tracks **smoke-only commits since the last full gate**; the hook
   **hard-blocks at N=5** (mirrors the existing additive-batch number), forcing a
   full run. The hard block IS the mechanism — the counter does no work beyond
   its ceiling (the DA's anti-rot finding). NO `.perf_debt` counter: perf is a
   Phase-boundary / pre-tag ritual the boundary checklist already enforces, not a
   per-commit-counted debt.

5. **Always commit BEFORE launching the full batched gate** so its reference
   point is a real SHA (a red maps to a committed SHA, enabling fix-forward;
   never a vanished working-tree state). Trust `SENTINEL-EXIT=0` +
   `.gate_pass == gate_state_hash.sh`, NEVER the task-completion notification
   (`premature_gate_notification`).

6. **Red-gate handling records the LAYER.** A full-gate red in `zig build test`
   (the oracle/unit layer) is an F-012 divergence: if any later commit built on
   the broken module, **revert + re-validate** (a parity break downstream-depended
   on cannot be fix-forwarded). A red in a batched e2e-SHELL step with no semantic
   dependents → **fix-forward** (next commit is the fix). The full gate is run
   ALONE (decision §2), so its reds are trustworthy (not load flakes).

### NOT adopted (the DA was decisive)

- **dev ∥ gate concurrency** — unsafe (the e2e -P8 pool false-times-out under
  load even alone; concurrent `zig build` worsens it + corrupts the shared
  binary). The win is the fast smoke, not parallelism.
- **diff-case subset in smoke** — strictly worse than free; the full oracle is
  already in `zig build test`, which smoke runs in full.
- **`.perf_debt` / `.gate_red` async-flag machinery** — over-engineered rot
  surface; one ceiling counter + boundary rituals suffice.

## Miss-window (the honest cost)

Smoke runs `zig build test ×2` (all unit + the full diff oracle) + the changed
e2e, but NOT all 248 e2e shell steps. So a shared-file change (analyzer/reader)
that breaks an **unrelated, un-unit-testable shell behaviour** (CLI rendering,
exit codes, REPL/nREPL, require-filesystem, http server, GC torture) is caught
only at the batch/boundary gate, ≤ 5 commits later, needing a bisect over that
small range. Mitigations: N ≤ 5; for a **shared-file** diff run the full e2e set
rather than only-changed when convenient; give new shell-only behaviours a
diff/unit case where feasible so the window keeps shrinking. Evaluation-semantic
regressions are NOT in the window — they are caught by the diff oracle / unit
tests inside `zig build test`, which smoke always runs in full.

## Alternatives considered (Devil's-advocate, fresh context — verbatim)

> Active constraints: F-012 dual-backend oracle, releasability at Phase/tag
> boundaries, F-002 finished-form, orphan-prevention. LOC/diff size is not one.

**Headline finding:** the original draft split on the wrong axis
(correctness-vs-perf) and proposed a diff SUBSET in smoke — strictly worse than
free, since the full diff oracle is already inside `zig build test` (fast,
contention-tolerant). The correct smoke is the full `zig build test ×2` + changed
e2e; batch only the slow e2e SHELL suite. This also collapses the multi-counter /
async-flag machinery as over-engineered.

**Alt A — smallest-diff: keep gate_cadence.md, only add `run_all.sh
--no-e2e-shell`.** The "full gate" the existing hook demands becomes
`zig build test ×2 + lint + build + corpus` (no e2e shell / perf); the 248 e2e +
perf batch via the existing `.gate_cadence` counter + Phase boundaries. *Better:*
near-zero new machinery (reuses hook/counter/fingerprint/`--only`). *Breaks:* the
risky-vs-additive classifier still over-gates some commits; the e2e-shell
miss-window remains.

**Alt B — finished-form-clean (RECOMMENDED): two-tier split on unit-vs-e2e.**
`--smoke` (zig build test ×2 + lint + build + corpus + changed e2e, ~fast) stamps
`.smoke_pass`; full gate adds e2e shell + perf, stamps `.gate_pass`. Per-commit
authorised by `.smoke_pass`; one e2e-batch ceiling (N=5) + Phase/tag boundary
force full + perf run-alone. No async, no concurrency, no perf counter. *Better:*
keeps 100% of the F-012 oracle per commit; smallest miss-window; two fingerprint
files mirror the existing `.gate_pass` the hook understands. *Breaks:* needs a
changed-e2e→diff mapping (conservatively: run all e2e for shared-file diffs,
only-changed for additive); the small e2e-shell window is non-zero.

**Alt C — wildcard: post-commit advisory async full gate, no ceiling.**
Per-commit = `zig build test ×2 + lint + build` only; fire a `timeout 1800 …
--serial-e2e` background gate whose red is advisory. *Better:* fastest iteration.
*Breaks:* this is the unsafe concurrency premise — async serial-e2e under
concurrent `zig build` false-reds, and an ignored advisory red is exactly the
2026-05-31 debt-rot. Recommend against (trades a real correctness signal for
speed; violates the F-012 spirit).

**DA recommendation: Alt B** — finished-form-clean, preserves the dual-backend
oracle in full per-commit, keeps boundary releasability rituals, no orphan-prone
background machinery. Adopted.

## Risks (from the DA)

1. **E2e-shell miss-window** (above) — caught at batch/boundary, ≤5-commit
   bisect. Mitigate with small N + full-e2e on shared-file diffs.
2. **Oracle-red downstream contamination** — a `zig build test` parity red that
   later commits depended on needs revert, not fix-forward. The full gate runs
   alone so its reds are real; record the layer (oracle vs e2e-shell).
3. **Counter rot** — only the hard ceiling block enforces a drain; keep one
   counter, perf is a boundary ritual (no counter).
4. **Concurrency is unsafe** — any batched gate is `timeout`-wrapped,
   `--serial-e2e`, run-alone; never auto-block on a possibly-flaky e2e red.
5. **Premature notification** — trust `SENTINEL-EXIT` + fingerprint, not the
   completion notification.

## Consequences

- Per-commit iteration drops from ~5 min to the smoke cost (`zig build test ×2`
  dominated, ~tens of seconds), keeping the full F-012 oracle every commit.
- The slow + flaky e2e shell suite + perf move to a batched, run-alone gate
  (every ≤5 smoke commits + Phase/tag boundaries).
- New: `run_all.sh --smoke` + `.dev/.smoke_pass`; `check_gate_cadence.sh` accepts
  smoke authorization + a smoke-batch ceiling. No async/concurrency machinery.

## Affected files

- `test/run_all.sh` — `--smoke [e2e-step,…]` mode (run the correctness core +
  named e2e; stamp `.dev/.smoke_pass`).
- `scripts/check_gate_cadence.sh` — accept `.dev/.smoke_pass` as commit
  authorization; smoke-batch ceiling (block at N forcing a full gate).
- `scripts/gate_state_hash.sh` — reused for the `.smoke_pass` fingerprint.
- `.claude/rules/gate_cadence.md` — **rewrite to this two-tier policy. Rule
  edits are permission-blocked for the loop (see memory); this is USER-OWNED.**
  Until rewritten, this ADR is the authoritative policy and the scripts enforce
  it; the rule text is updated by the user to match.
- `private/notes/` — the broad-reprobe + this ADR's measured smoke timing.

## Rule edit (user-owned)

`.claude/rules/gate_cadence.md` is the auto-loaded SSOT summary; rewriting it to
the two-tier policy is required for consistency but is **permission-blocked for
the autonomous loop**. Surfaced to the user. The scripts + this ADR carry the
enforceable policy in the meantime.

## Revision history

### 2026-07-21 — CI runs the full gate on push-to-main (not just nightly)

The batched-full-gate cadence above is a *local* discipline. CI had mirrored it
too literally: `.github/workflows/ci.yml` ran the fast CORE tier (`--smoke`, **no
e2e**) on both PR *and* push-to-main, and the full e2e suite only on the nightly
schedule. So a shared-code change that broke an e2e step (not the changed step's
own smoke) passed the push CI and sat on `main` until the next nightly failed —
observed as the D-316 `def`-meta change breaking `phase14_var_metadata.sh`, which
failed four consecutive nightlies (2026-07-18..21) before being caught. That
made CI the *late* detector and left "the local full gate" and "CI" inconsistent.

Fix: **push-to-main now runs the FULL gate** (`CLJW_CI_FULL=1` for every event
except `pull_request`), so every landed commit is e2e-verified by exactly the
local full gate (`test/run_all.sh --serial-e2e`). PR stays fast CORE for
iteration (its merge fires a push event that runs the full gate before it
lands). The heavier non-default-backend (tree_walk) parity sweep — a second
ReleaseSafe rebuild, **not** part of the local full gate — moved to its own
`CLJW_CI_PARITY` flag and stays nightly/dispatch-only, so it is an extra backstop
rather than a source of push-vs-local drift. `concurrency: cancel-in-progress`
already collapses a rapid push burst to one completing full run, so the added
per-push cost is bounded.

Affected: `.github/workflows/ci.yml` (event→flag mapping), `scripts/ci_gate.sh`
(the parity sweep split onto `CLJW_CI_PARITY`).
