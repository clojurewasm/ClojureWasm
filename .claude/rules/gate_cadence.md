---
paths:
  - "test/run_all.sh"
  - "test/**/*.sh"
  - "scripts/run_gate.sh"
  - "scripts/gate_state_hash.sh"
  - "scripts/check_gate_cadence.sh"
  - ".claude/settings.json"
---

# Gate cadence (smoke per-commit, batch the full gate)

Auto-loaded when editing the test runner / hook scripts / settings.
Codifies *when* the fast smoke (`bash test/run_all.sh --smoke`, ~tens of
sec) vs the full Mac gate (`bash test/run_all.sh`, **~5 min** — the 248
e2e shell steps grew heavy) must run, and makes the policy
**mechanically enforced** rather than prose. SSOT for the decision is
[ADR-0107](../../.dev/decisions/0107_pipeline_gate_smoke_authorized.md).

## Why

The full gate is now **~5 min**, ~60% of it the 248 e2e shell steps,
which also false-time-out under host load (the `gate_parallel_e2e_timeout`
memory). Running it per commit was the iteration bottleneck. ADR-0107
found the cost/risk axis is **unit-vs-e2e, not additive-vs-shared**:

- `zig build test` on **both** backends IS the entire F-012 correctness
  guarantee — `src/lang/diff_test.zig` (the dual-backend differential
  oracle) is `@import`ed from `src/main.zig`, so every diff case runs
  inside it. It is timing-independent, contention-tolerant, and fast-ish.
- The 248 e2e shell steps + perf/bench are the slow, load-flaky part —
  the only part worth batching.

So the smoke = the fast correctness core (both-backend `zig build test`
+ zlinter + `build_cljw` + `corpus_regression` + **the changed e2e
step(s)**). Because it carries the full diff oracle, the smoke
**authorises shared-code commits too** — the old "additive vs risky"
split is retired. Only the full e2e suite is deferred.

So: **smoke every commit (shared-code included), batch the full gate.**

## The policy

| Commit class   | Definition                                                                        | Gate requirement                                                                               |
|----------------|-----------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------|
| **Non-source** | No `src/` / `test/` / `build.zig*` staged (docs, `.dev/`, `.claude/`, `scripts/`) | Exempt — never gated, never counted                                                           |
| **Source**     | Touches `src/` / `test/` / `build.zig*` (additive OR shared-code, no distinction) | A fresh **smoke** authorises it; may ride up to **5** since the last full gate, the 6th blocks |

A fresh **full gate** clears the batch counter (the next 5 ride again).
"Fresh" (smoke or full) = ran to green on the **exact content** being
committed (the `gate_state_hash.sh` fingerprint matches). The full gate
is `test/run_all.sh` with no `--only`/`--skip`, run ALONE (`--serial-e2e`
for determinism), at the 5-commit ceiling / Phase boundary / pre-tag.

## Enforcement (ADVISORY since 2026-06-11 — effort-goal, not a hard block)

> **User-directed 2026-06-11**: `check_gate_cadence.sh` no longer *blocks*
> commits. The smoke-per-commit / batch-the-full-gate cadence below is an
> **effort-goal (努力目標)** — the hook prints a `⚠ advisory` recommendation and
> exits 0. It was over-strict (it blocked + forced a re-smoke when the md-table
> hook reformatted a `test/` doc mid-commit). The smoke/full-gate discipline is
> still the right rhythm — run it — but it is now self-enforced, not hook-blocked.
> The description below documents the *recommended* cadence; "blocks" / "law"
> wording is historical.

### Recommended cadence (was: mechanical enforcement)

- **`scripts/gate_state_hash.sh`** — prints a fingerprint by hashing the
  *content* (path + bytes) of every tracked or untracked-non-ignored file
  under `src/` + `test/` + `build.zig*` (`bench/` excluded). Hashing
  content — not a diff vs HEAD — makes the fingerprint independent of HEAD
  position and of staging, so it still matches after `git add` and survives
  a `git add && git commit` batched into one shell command.
- **`test/run_all.sh`** — a **full** green gate (no `--only`/`--skip`) writes
  the fingerprint to `.dev/.gate_pass` AND clears the batch counter
  `.dev/.gate_cadence` to 0; a **`--smoke`** green writes it to
  `.dev/.smoke_pass` (all gitignored). A full gate validates everything up
  to now, so the batch restarts; a smoke validates the fast core for this
  exact content.
- **`scripts/check_gate_cadence.sh`** — PreToolUse hook on `git commit`.
  Reads the change from **`git diff HEAD` + an untracked listing** (NOT
  `git diff --cached`): a PreToolUse hook fires *before* the command, so
  `git add … && git commit` batched into one call leaves the index empty at
  hook time — `--cached` would see nothing and wrongly exempt the commit.
  Non-source change ⇒ exempt. Source change ⇒ authorised iff the current
  fingerprint equals `.dev/.gate_pass` **or** `.dev/.smoke_pass` (ADR-0107):
  a `.gate_pass` match resets the counter; a `.smoke_pass`-only match
  consumes a batch slot and **hard-blocks at the 6th** (forcing a full
  gate). A source change with neither fingerprint fresh ⇒ block (smoke it
  first).

`git commit --no-verify` is denied in `.claude/settings.json`, so the
hook cannot be bypassed. `GATE_MAX_BATCH` (default 5) is overridable
via env for a one-off.

**Clean-tree implication.** Because classification reads the whole working
tree vs HEAD (not just the index), a dirty source file with no fresh
fingerprint blocks **every** commit until it is smoked, reverted, or
committed — even a doc-only commit. This is intentional: it enforces the
edit → smoke → commit rhythm (one unit at a time, clean tree between
units). Stage-and-commit a unit before starting the next; don't leave a
half-done source edit lying beside an unrelated commit.

## Workflow it produces

- Coverage / feature sprint: edit → `bash test/run_all.sh --smoke <step>`
  (background it, don't block) → commit. Up to 5 such commits ride without
  the full gate. Run `bash test/run_all.sh` (ALONE) on the 5th (or whenever
  convenient) — a full green gate clears the batch counter, so the next 5
  commits ride again. (A subsequent commit whose exact content the gate
  verified is also authorised as "fresh" and zeroes the counter.)
- Shared-code change: same path — the smoke carries the full both-backend
  diff oracle, so it authorises shared-code too (the old "risky ⇒ full
  every time" rule is retired per ADR-0107). The full gate still catches
  the e2e-shell miss-window (≤ 5 commits) at the ceiling / boundary.

The `--smoke` run is expected on **every** source commit — the batching
only defers the slow *full* e2e suite, never the smoke. Manual behaviour
probes use a **ReleaseSafe** binary (`zig build -Doptimize=ReleaseSafe
-Dcpu=baseline`), not the Debug default (memory `verify_against_releasesafe_binary`).

## Forward-looking (framework_completion note)

Per `framework_completion.md`, a new hook must state its discovery
criterion + sweep. This hook is **forward-looking** (like
`orphan_prevention.md`): it constrains *future* commits' cadence and
retrofits no existing code, so there is no existing-site population to
sweep. The "discovery recipe" is the classifier in
`check_gate_cadence.sh` itself, applied per future commit.

## Stale-ness

Stale if: the smoke stops being ≤ ~60s or the full gate's e2e-vs-unit
cost asymmetry changes (re-measure); a new shared-risk surface the smoke
core does NOT cover appears (the miss-window grows beyond CLI/REPL/
filesystem/http/GC e2e — re-scope what the smoke runs); or the batch of
5 proves wrong in practice.

## Related

- [ADR-0107](../../.dev/decisions/0107_pipeline_gate_smoke_authorized.md) —
  the two-tier decision this rule is the SSOT for; the miss-window analysis.
- `.claude/rules/orphan_prevention.md` — sibling forward-looking hook.
- `scripts/check_smell_audit.sh` — the other `git`-time blocking hook.
- CLAUDE.md § Autonomous Workflow Step 5 (test gate) / Step 6 (commit).
- memory `smoke_first_batch_full_gate` + `verify_against_releasesafe_binary`.
