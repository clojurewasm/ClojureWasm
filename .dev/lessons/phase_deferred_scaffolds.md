# Lesson — Phase-deferred scaffolds lose their homing path

- **Date**: 2026-05-25 (surfaced via zwasm v2 reciprocal observation
  at `private/notes/zwasm_v2_reciprocal_observations.md`)
- **Cluster**: A (Implementation patterns) + E (Debugging and
  tooling)
- **Promoted to lesson** at Wave 16 W16-7 (2026-05-26); previously
  lived inline in `.claude/rules/zig_tips.md` L313-358.

## Observation

A file landed for a future phase, expecting some upstream wiring,
but the wiring never arrives. The file sits in the source tree
without any production-path caller. Two symptoms emerge:

1. **Test-orphan**: the file has `test {...}` blocks that never
   run, because Zig's lazy declaration analysis only pulls a file
   into the test graph when something else references it.
2. **Compile-error-orphan**: the file references stale stdlib APIs
   that never get checked, because the file is never compiled.

Both root in: "we landed code expecting future wiring; future
wiring never came; code sits without a caller."

## Concrete events

- 2026-05-25 surgery: `runtime/regex/{compile, match}.zig`
  skeletons shipped with 13 unit tests that never ran. Discovered
  during the cycle-1 commit; fix landed via `src/main.zig`'s
  `test {}` aggregator block + the new
  `scripts/check_test_reach.sh` gate.
- D-053: `runtime/clock.zig` + `runtime/time/instant.zig`
  referenced `std.time.nanoTimestamp`, which was removed in Zig
  0.16. The orphan-status meant no one type-checked these files
  for multiple commits.
- 2026-05-26 review-fix on commit ef4f683: silent-failure-hunter
  surfaced 5 missed retrofit sites in the Wave-15 provisional-
  marker spike (same shape — code landed expecting later wiring
  + the discovery criterion was implicit). Wave 16 W16-1
  introduced `framework_completion.md` to codify the discovery-
  criterion + sweep + retrofit triad.

## Lesson

When a Phase-deferred scaffold lands, the author should:

1. Put a `_ = @import("path/to/scaffold.zig");` line in
   `src/main.zig`'s `test {}` aggregator block in the same
   commit, so the file is in the test graph from day one
   (covers both orphan symptoms above).
2. If the scaffold is genuinely too disruptive to compile until
   the deferred phase lands (rare), file an explicit
   `D-NNN blocked-by: Phase N landing` row in `.dev/debt.md`
   so the deferral has a tracked owner — not a silent orphan.

## Complementary detection layers cw v1 carries

- **Test-presence orphan check** (`scripts/check_test_reach.sh`)
  — high signal, allow-list-free, hard-fail gate.
- **Lazy decl analysis ride-along** — once a file enters the
  test graph, latent compile errors against removed stdlib APIs
  surface immediately. The check_test_reach gate is therefore
  also a covert "is the code still buildable" gate for files
  with no production-path caller.
- **Periodic debt review** — `Phase N target` /
  `blocked-by: <event>` rows in `.dev/debt.md` that have been
  blocked for ≥ 3 cycles get escalated at Step 0.5 sweep.

## The aspirational-rule sibling

A related shape: a `.claude/rules/<X>.md` that declares an
enforcement (e.g., "Phase 5+ becomes a hard gate") without a
matching script — the rule is aspirational but no mechanical layer
enforces it. zwasm v2's `audit_table_sync.sh` is the canonical
"aspirational rule lifted to a mechanical gate" pattern; Wave 16
W16-3 did the same for `handover_framing.md` forbidden phrases.

## Related ADRs

- ADR-0021 (test taxonomy) — the 5-layer test framework that
  `check_test_reach.sh` operationalises.
- ADR-0024 (scan framework + run_step) — the gate-runner shape
  this lesson's detection layers fit into.

## Related Wave-16 follow-up

The Wave-16 framework_completion.md rule + watch_findings.md SSOT
+ Bad Smell "Framework-incomplete" / "Defer-to-amnesia" entries
formalise the discipline this lesson surfaced.
