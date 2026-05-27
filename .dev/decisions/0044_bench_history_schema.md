# 0044 — `bench/history.yaml` schema (per-commit aggregate with machine + distribution)

> **ADR-number history note**: this ADR was originally drafted at
> slot `0027` (commit `8678052`, 2026-05-27 row 8.2) but collided
> with `0027_nan_box_second_generation.md` (issued 2026-05-24 row
> 5.2.b). The Phase 8 → 9 boundary audit caught the collision; ADR
> numbers are time-ordered `max+1` at issue per CLAUDE.md §
> Project spirit. Renumbered to `0044` at the Phase 8 → 9 audit
> absorption commit. Callers (`.dev/handover.md`, `.dev/ROADMAP.md`,
> `bench/history.yaml`, debt rows) were updated in the same commit.

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-27)
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: bench, regression-gate, schema, F-001, F-002, F-003, D-005

## Context

Phase 8 row 8.2 opens `bench/history.yaml` — the curated reference
layer the row 8.3 1.2x regression gate compares against. Today cw
v1 has:

- `bench/quick.sh` (113 LOC) — CI-time bench runner; appends TSV
  samples to `bench/quick_baseline.txt`.
- `bench/quick_baseline.txt` (5 789 lines at HEAD `d810322`) — flat
  TSV log of `<timestamp> <phase> <bench_name> <value>` rows. Mac
  and OrbStack Linux samples interleave with no machine
  differentiation. No commit SHA, no backend field, no σ-data.
- 5 `bench/fixtures/<name>.clj` programs feeding `quick.sh`'s 5
  fixture benches + 4 derived metrics (binary size, cold start,
  e-plus round-trip, read-100-forms).

The 5 789-line append-log is fine as **high-volume telemetry** but
the row 8.3 gate needs a **curated lock layer** carrying:
- Per-(machine, backend) baseline numbers.
- σ-data (median + p99 + samples) so D-005 Phase-17 σ-gate
  refinement consumes the same source without re-collection.
- Commit + reason annotation so the gate's diagnostic can say
  "regression vs lock-point `8A.0` from `d810322`".

Row 8.2's Step 0 survey
(`private/notes/phase8-8.2-survey.md`, 408 lines) recommends cw v0
shape (c) "per-commit aggregate" with two cw v1-specific
amendments (machine bucket + distribution stats). The
Devil's-advocate fork
(`private/notes/phase8-8.2-da-fork.md`, 336 lines, fresh context)
considered three alternatives within the F-NNN envelope, confirms
shape (c) with no further amendment beyond noting one operational
invariant for the future `bench/record.sh` helper.

cw v0 (`~/Documents/MyProducts/ClojureWasm/bench/history.yaml`,
1 149 LOC over 42 entries) ships shape (c) directly. cw v1 forks
the schema for the two amendments below.

## Decision

Adopt **shape (c) per-commit aggregate** for `bench/history.yaml`
with the cw v1-specific amendments noted below. Curated by an
explicit `bench/record.sh --id=<id> --reason=<reason>` helper
(landed in cycle 2 alongside the row 8.3 gate); the CI
`quick.sh` append flow is unchanged.

### Schema

```yaml
# bench/history.yaml
schema_version: 1                  # increments on breaking schema change
env:                               # file-global default machine (= row's omit case)
  cpu_arch: aarch64                # narrow info; per-entry `machine:` overrides
  os: Darwin
  tool: bash + EPOCHREALTIME (Zig hyperfine equivalent at Phase 17+)
entries:
  - id: "8A.0"                     # short curated label (PhaseLetter.cycle)
    date: "2026-05-27"             # YYYY-MM-DD
    reason: "Phase 8 row 8.2 — initial lock-point for the new schema"
    commit: "d810322"              # short SHA at lock time
    build: ReleaseFast             # default for quick.sh
    backend: tree_walk             # one of: tree_walk, vm, (future: wasm)
    machine:                       # per-entry machine bucket (cw v1 amendment)
      id: mac-arm-m4pro            # canonical short id for the gate to key on
      cpu: Apple M4 Pro
      cpu_arch: aarch64
      os: Darwin 25.5.0
      cores: 12
    lock: true                     # row 8.3 gate consumes only `lock: true` entries
    results:                       # per-bench distribution (cw v1 amendment)
      fib_recursive:
        samples_us: [3200, 3180, 3220, ...]   # raw samples for σ-gate
        median_us: 3200
        p99_us: 3260
        n: 50
      arith_loop: { ... }
      ...
```

### cw v1 amendments vs cw v0 shape (c)

1. **`machine:` per-entry block** (cw v0 had file-global only).
   Required: cw v1 runs the gate on both Mac (aarch64-darwin) and
   OrbStack Ubuntu x86_64 per the dual-host discipline; bench
   numbers cross the two hosts by >5×, so cross-machine
   normalisation is infeasible. The gate keys on
   `(machine.id, backend)` tuples.
2. **`results.<bench>.{samples_us, median_us, p99_us, n}`** instead
   of cw v0's mean-only. Preserves σ-data so D-005 Phase-17
   σ-gate refinement (an existing forward debt row) consumes
   `history.yaml` directly without re-collection. Median (not
   mean) per bench because cold-cache outliers in `cold_start_us`
   skew the mean meaningfully.

### Lock mechanism

- **In-band `lock: true` flag** on the entry. The row 8.3 gate
  iterates `entries:` for entries with `lock: true` matching the
  current (machine.id, backend), compares the latest
  `quick_baseline.txt` block's median against the lock's
  `median_us` per bench, raises on >1.2× regression.
- Curated by `bench/record.sh --id=<id> --reason=<reason>` (lands
  cycle 2). Auto-CI never appends to `history.yaml`; only the
  explicit helper does. This keeps `history.yaml` curated +
  small (cw v0's 42 entries over 24 phases ≈ 1.7 entries/phase).

### `reason:` field duplication invariant

When an `id:` spans multiple `(machine, backend)` entries (e.g.
the same lock-point recorded for Mac tree_walk + Mac vm +
Linux tree_walk + Linux vm), the `reason:` field repeats. cw v1's
`record.sh` enforces: `--id=X --reason=Y` always writes the same
`(id, reason)` pair across all 4 entries; reviewer reads only the
first one. Future depth-3 concern (reshape to lock-point-level
hoisting) deferred to a new debt row if duplication actually
bites at Phase 12+.

### Two-file role split

- `bench/quick_baseline.txt` — CI telemetry. Cheap append per
  bench run. The row 8.3 gate reads only the **latest block** for
  median computation.
- `bench/history.yaml` — curated locks. Only `record.sh` writes.
  Row 8.3 gate reads the matching lock-point per (machine,
  backend) for comparison.

Survey's "do not delete `quick_baseline.txt`" advice: the
historical samples stay valuable as forensic data even after the
gate switches to consuming `history.yaml`. The two layers are
complementary.

## Alternatives considered

(Devil's-advocate fork condensed from
`private/notes/phase8-8.2-da-fork.md`.)

### Alt 1 — Flat-record list

`entries: [{commit, date, bench_name, machine_id, backend,
sample_us}, ...]`. One row per (commit, bench, sample). Survey's
"shape (a)".

- Surface: ~450 LOC across schema + record.sh + gate.
- Better: simplest yq pipeline; append-friendly; smallest-diff
  from the current TSV log.
- Worse: **no raw samples means D-005 Phase-17 σ-gate refinement
  cannot consume `history.yaml`** (would need to re-collect
  samples after the schema lands). This conflicts with F-002 —
  the finished form requires σ-data preservation. DA's load-
  bearing objection.
- **F-002: violates** (forces a second migration at Phase 17).
- F-001 / F-003 / F-006 / F-009: neutral.

### Alt 2 — Per-commit aggregate (ADOPTED, = survey shape c)

(Decision section above.)

- Surface: ~475 LOC across cycle 1 + 2.
- F-002: positive (finished form, no Phase-17 migration).

### Alt 3 — Per-file split (`bench/history/<id>.yaml`)

One file per lock-point id. Git-native diff, no YAML merge
conflicts, O(1) atomic append.

- Surface: ~395 LOC (slightly less than Alt 2 because no `yq -i`
  edit dance).
- Better: file-per-lock means merge conflicts on parallel work
  don't accumulate; reviewer reads one file per lock.
- Worse: file count grows linearly with locks (cw v0's 42 entries
  → 42 files). Diverges from cw v0's reviewer muscle memory.
  Phase 16+ wasm divergence is better solved by a second file
  (cw v0 has a `wasm_history.yaml` precedent), not per-lock
  split.
- F-NNN: neutral on all 5 dimensions; rejected for operational
  continuity.

## Consequences

### Positive

- Row 8.3's 1.2x gate has a deterministic per-(machine, backend)
  comparison source.
- D-005 Phase-17 σ-gate refinement consumes `history.yaml`
  directly (no second-pass migration).
- Curation via `record.sh` keeps the file small + reviewer-
  friendly (vs auto-append from CI).
- cw v0's 42-entry track-record validates the schema's
  long-horizon scaling (~1 MB by Phase 20 per the DA's cost
  projection).

### Negative

- `reason:` field repeats across (machine, backend) variants of
  the same `id:` — accepted as the `record.sh` invariant
  (depth-1 mitigation per DA).
- The schema is structural; future divergence (e.g. JIT bench at
  Phase 17) needs a `schema_version: 2` bump + migration.

### Deferred

- `bench/record.sh` helper — cycle 1 lands the schema + first
  lock entry; the helper script lands at cycle 2 (= row 8.3's
  cycle 1 alongside the gate).
- `scripts/check_bench_regression.sh` — row 8.3 cycle 1.
- D-005 σ-gate (Phase 17 σ-aware gate) — independent of this ADR.
- Wasm-bench schema variant (F-001 Phase 16+ entry) — assumed to
  re-use this schema with a new `backend: wasm` value;
  schema_version bump only if a new field is required.

## Cross-references

- ROADMAP §9.10 row 8.2 (this row's task table entry).
- ROADMAP §10 (Performance) — original bench-gate target.
- ADR-0005 — dual-backend differential (row 8.4 full-bench remit
  rides on this schema).
- ADR-0023 — Phase-gated comptime bools (the row-8.4 `--compare`
  may surface as a Phase-N flag; out of scope here).
- F-001 — zwasm v2 unavoidable (forward-fitness check passed:
  schema absorbs `backend: wasm` without breaking shape).
- F-002 — finished-form cleanliness (decisive rejection of Alt 1).
- F-003 — decision-deferral on structural plans (row 8.2 is the
  owning Phase entry for the schema decision).
- D-005 — Phase-17 σ-gate refinement (downstream consumer of
  the `samples_us:` field this schema preserves).
- `private/notes/phase8-8.2-survey.md` — Step 0 survey.
- `private/notes/phase8-8.2-da-fork.md` — Devil's-advocate fork.
- cw v0 `~/Documents/MyProducts/ClojureWasm/bench/history.yaml`
  (1 149 LOC over 42 entries) — schema lineage anchor.
