# 0021 — Test layer taxonomy (5 layers, Phase 0-11 staged)

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, test, taxonomy, regression, dual-backend

## Context

cw v1 reaches Phase 4 with three different test surfaces already in
flight: inline Zig `test "..."` blocks per source file, e2e shell
scripts under `test/e2e/`, and a future `Evaluator.compare()`
runner that ADR-0005 marks as CI-mandatory from Phase 4. Without
a documented taxonomy:

- New tests get written wherever the author finds first; the
  "where does this test belong" question becomes a recurring
  review topic.
- Phase-by-phase test growth has no shape — at Phase 11 (upstream
  port) the testing layer's relationship to inline tests is
  unclear.
- The differential layer (TreeWalk vs VM) sits ambiguously between
  unit and e2e.

A long survey (private/research-2026-05-23/TEST_STRATEGY.md) listed
13 possible layers (unit / e2e / integration / differential /
golden / bench-quick / bench-full / conformance / property / fuzz /
concurrency / memory-leak / Wasm component). At Phase 4 entry that
list is overengineered.

## Decision

cw v1 commits to **5 test layers** at Phase 4 entry, with the
remaining 8 layers deferred and named explicitly so they can be
added without re-opening this decision.

| # | Layer        | Location                | Tool                             | Phase opens | Cadence                      |
|---|--------------|-------------------------|----------------------------------|-------------|------------------------------|
| 1 | Unit         | `src/**/*.zig` (inline) | `zig build test`                 | Phase 0     | every commit                 |
| 2 | E2E (CLI)    | `test/e2e/*.sh`         | bash + `cljw`                    | Phase 2     | every commit                 |
| 3 | Differential | `test/diff/`            | `Evaluator.compare()` (ADR-0022) | Phase 4     | every commit                 |
| 4 | Bench quick  | `bench/quick.sh`        | bash + `cljw`                    | Phase 4     | every commit (informational) |
| 5 | Conformance  | `test/clj/`             | `clojure.test`                   | Phase 11    | every PR                     |

### Phase-by-phase test growth (target, not KPI)

| Phase | cumulative tests | cumulative test files | new layer added                                |
|-------|-----------------:|----------------------:|------------------------------------------------|
| 0-3   |              ~80 |                   ~25 | Layer 1, 2                                     |
| 4     |             ~120 |                   ~32 | + Layer 3 (diff), + Layer 4 (bench quick)      |
| 5     |             ~250 |                   ~45 | growth in Layer 1 (collection / GC / lazy-seq) |
| 7     |             ~400 |                   ~60 | growth in Layer 1 (multimethod / protocol)     |
| 11    |           ~3,000 |                   ~90 | + Layer 5 (Upstream port)                      |
| 15    |           ~3,500 |                  ~105 | growth in Layer 1 (STM / atom / concurrency)   |
| 20    |     ~4,000-4,500 |                  ~120 | (final)                                        |

These are **targets**, not gates. The Phase 4 gate is "all
landed tests pass on both backends", not "we have at least 120
tests".

### Deferred layers (named so the future expansion is mechanical)

| Future layer    | Triggers at                                 | Future ADR                                      |
|-----------------|---------------------------------------------|-------------------------------------------------|
| Integration     | Phase 5 (collection + GC + reader together) | (no ADR; just a `test/integration/` directory)  |
| Golden snapshot | Phase 7+                                    | ADR-0026 (future)                               |
| Property-based  | Phase 8+                                    | (no ADR; `test/prop/` directory)                |
| Fuzz            | Phase 6+                                    | (no ADR; `fuzz/` directory; cadence weekly)     |
| Memory leak     | Phase 5+ (GC activation)                    | (no ADR; ReleaseSafe + `--gc-stress`)           |
| Concurrency     | Phase 15+ (STM / atom / lock activation)    | (no ADR; runs in Layer 1 with `--test-iter`)    |
| Bench full      | Phase 8 (lock baseline; landed at row 8.2)  | ADR-0044 (was 0027 pre-audit; renumbered)       |
| Wasm component  | Phase 14+                                   | (no ADR; runs in Layer 2 with Wasm Pod fixture) |

### Layer 3 (Differential) wiring

ADR-0022 specifies the implementation contract for the
differential layer. This ADR (0021) only places it in the taxonomy;
the runner / cases.yaml shape lives in 0022.

### Layer 5 (Conformance) deferral

`test/clj/skip_taxonomy.yaml` (the YAML that maps every upstream
test file to a tier classification) is **not** drafted at Phase 4
entry. ADR-0025 (future, Phase 11 entry) finalises that schema.

## Alternatives considered

### Alternative A — 13 layers from day 1

- **Sketch**: open `test/{integration,golden,prop,fuzz,memleak,concurrency,bench-full,wasm}/` at Phase 4 entry with placeholder READMEs.
- **Why rejected**: 8 empty directories add maintenance friction
  without value before Phase 5-11.

### Alternative B — 3 layers (unit / e2e / conformance)

- **Sketch**: merge differential into e2e, drop bench-quick.
- **Why rejected**: ADR-0005 has differential as a separate
  surface with `Evaluator.compare()` — collapsing into e2e loses
  the per-backend visibility. bench-quick is Phase 4 task 4.0,
  also a separate surface.

## Consequences

- **Positive**: the "which layer is this test" question has 5
  answers at Phase 4, and the Phase 11+ growth is mapped. Reviewers
  can flag a misplaced test against the table.
- **Negative**: future layer additions must respect the deferred
  layer naming so subsequent ADRs can refer to them.
- **Neutral / follow-ups**: `test/README.md` lists the 5 layers
  with one-line guidance for "which to use when". A new
  `.claude/rules/test_taxonomy.md` enforces the choice when an
  agent writes a test.

## Affected files

- `.dev/ROADMAP.md` §11 — rewrite per 5-layer taxonomy + Phase
  growth table
- `.dev/ROADMAP.md` §11.3 — fix Phase 8 → Phase 4 (ADR-0005 has
  this from Phase 4)
- `.dev/ROADMAP.md` §11.6 row 6 — same fix
- `test/README.md` (new) — 5 layers with guidance
- `.claude/rules/test_taxonomy.md` (new, in follow-up commit) —
  enforcement of placement

## References

- ADR-0005 (Dual-backend differential — Layer 3 owner)
- ADR-0022 (Differential test wiring — Layer 3 implementation)
- ADR-0025, ADR-0026, ADR-0044 (bench schema; was ADR-0027 pre-audit)
- `private/research-2026-05-23/TEST_STRATEGY.md` (working notes)
- `private/research-2026-05-23/REVIEW_TEST_STRATEGY.md` (review
  that triggered the 13 → 5 reduction)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
