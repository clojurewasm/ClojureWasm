---
paths:
  - "bench/**"
  - ".dev/optimizations.md"
  - "scripts/perf.sh"
  - "scripts/run_gate.sh"
  - "test/run_all.sh"
---

# Measure perf in Release, never Debug

Auto-loaded when touching perf surfaces (`bench/`, `.dev/optimizations.md`,
`scripts/perf.sh`, `// PERF:`-marked code). The principled guard against
the 2026-05-31 incident where a whole perf "campaign" chased **Debug-build
ghosts**.

## The rule (mechanical)

**Measure cljw runtime speed ONLY through `scripts/perf.sh`** (or the
ReleaseFast `bench/`). It builds an optimised binary into a separate
prefix and times that. **NEVER `time zig-out/bin/cljw`** — that binary is
**Debug**.

```sh
bash scripts/perf.sh '(count (vec (range 1000000)))'   # ReleaseFast, 3 runs
CLJW_PERF_MODE=ReleaseSafe bash scripts/perf.sh '...'  # match cw-v0's mode
```

## Why (the incident)

`build.zig` uses `standardOptimizeOption(.{})`, so **`zig build` (no
`-Doptimize`) defaults to Debug** — deliberately, for fast dev/TDD
iteration. A Debug build of a tree-walk interpreter runs **~10-100× slower**
than the shipped build, so Debug perf numbers are meaningless. Measured
2026-05-31 (same code, same expr):

| expr                            | Debug (`zig build`) | ReleaseFast (`scripts/perf.sh`) |
|---------------------------------|---------------------|---------------------------------|
| `(count (vec (range 1e6)))`     | ~121s (pre-O-003)   | ~0.02s                          |
| `(count (map inc (range 1e5)))` | ~41s (pre-O-004)    | ~0.01s                          |
| startup `cljw -e 1`             | ~0.48s              | ~ms (cw v0 claims ~4ms)         |

The "あからさまに遅い" pathologies that motivated O-001..O-004 were
**Debug artifacts**; cljw already meets the ms-level cold-start mission
target in Release. The algorithmic wins (O(n) over O(n log n), chunked
iteration) still help in Release, but the urgency/framing was Debug-driven.
Any future perf claim MUST cite a `scripts/perf.sh` (Release) number.

## Build-mode policy (structural unification)

| Path                                    | Build mode  | Why                                                       |
|-----------------------------------------|-------------|-----------------------------------------------------------|
| Shipped binary / `cljw build`           | ReleaseSafe | optimised + all safety checks                             |
| Gate e2e (`build_cljw`)                 | ReleaseSafe | `run_all.sh` exports `CLJW_OPT=ReleaseSafe`               |
| `phase4_*` backend e2e                  | ReleaseSafe | unified 2026-05-31 (was `:-Debug` standalone default)     |
| **Gate unit tests (`zig build test`)** | **ReleaseSafe** | **D-487 flip (2026-06-21): the F-012 diff oracle RUNs many programs on the interpreter → RUN dominates; Debug hits the perf cliff. ReleaseSafe keeps ALL safety checks, only drops 0xAA poisoning (oracle doesn't depend on it). Gate steps pass `-Doptimize=ReleaseSafe`.** |
| Dev `zig build test` (bare, no -Doptimize) | Debug    | max diagnostics (0xAA undefined-poisoning) for deep debugging — dev opt-in, NOT the gate |
| Dev `zig build`                         | Debug       | fast TDD iteration; NEVER time this binary                |
| Perf measurement                        | ReleaseFast | `scripts/perf.sh` only                                    |

### D-487 — why the gate's unit tests flipped Debug → ReleaseSafe (2026-06-21, user-flagged)

The user flagged the smoke being slow. Root cause: `zig build test` ran **Debug**, and
because `src/lang/diff_test.zig` (the F-012 dual-backend diff oracle) is `@import`ed into
the test set, the test **RUN** evaluates many programs on the Debug interpreter — the
Debug perf cliff (e.g. `(count (vec (range 1e6)))` = Debug 121s vs Release 0.02s). **Measured
2026-06-21**: a test build = Debug ~200s vs **ReleaseSafe ~59s cold / ~1.0s warm** — 3.4×
cold, ~200× warm — with **all tests still PASS** (ReleaseSafe keeps bounds/overflow/UB
panics; only Debug's `undefined`-poisoning is gone, which the value-equality oracle does
not rely on). Alternatives considered: **(a) keep Debug** (status quo — rejected: 3.4–200×
slower for zero gate benefit, the urgency the user raised); **(b) ReleaseSafe** (chosen —
strictly faster, safety preserved); **(c) a build-flag toggle** (rejected as over-built —
bare `zig build test -Dwasm` ALREADY stays Debug for a dev who wants undefined-poisoning, so
no new knob is needed; the gate just hard-codes ReleaseSafe). The earlier Debug-for-unit-tests
rationale ("fast compile") was BACKWARDS for this codebase — the diff oracle makes the RUN,
not the compile, the cost.

So: everything **perf-relevant** is optimised, AND the gate's unit-test RUN (the diff
oracle) now runs ReleaseSafe so the gate is fast. Debug stays available via the bare
`zig build test -Dwasm` dev invocation for undefined-poisoning diagnostics. Debug stays the dev default purely
for build-iteration speed.

## Related

- `scripts/perf.sh` — the blessed measurement entrypoint.
- `.claude/rules/perf_marker.md` — `// PERF:` markers (cross-links here).
- `.dev/optimizations.md` — the O-NNN ledger; every row's numbers must be
  Release (`scripts/perf.sh`), not Debug.
