# 0024 — Source-scan framework + run_step runner pattern

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, gate, scan, runner, bash

## Context

Two related concerns surface at Phase 4 entry:

1. **Source-scan gates**. cw v1 has 4 scripts that grep `src/` for
   forbidden patterns (`check_compat_tiers_sync.sh`,
   `check_no_op_stub.sh`, `check_tier_d_error_msg.sh`,
   `file_size_check.sh`). Each was written independently with
   slightly different output formats and informational-vs-gate
   handling. ADR-0018 and ADR-0019 will add two more
   (`scan_catalog_only.sh`, `scan_panic_audit.sh`). Without a
   shared library, the divergence compounds.

2. **Test runner dispatch**. `test/run_all.sh` is the single
   entry point but currently shells out to each gate in series
   with no summary, no skip / only flags, and no per-step timing.
   zwasm v1's `run_step` pattern shows the value of these
   features at modest cost.

The two concerns share `bash` as their substrate and benefit from
landing together (the scan scripts use the same logging helpers
that the runner uses).

## Decision

### Part 1 — `scripts/scan_lib.sh`

A bash library that every source-scan script sources. Provides:

- `scan_mode()` — returns `informational` (default) or `gate`
  based on `$CLJW_SCAN_MODE` env var. Phase 5+ flips the default
  to `gate`.
- `scan_count(pattern, dir)` — counts pattern hits.
- `scan_match_in_dir(pattern, dir)` — lists hits with file:line.
- `scan_report(gate_name, hits, threshold)` — prints
  `[<gate>] PASS/FAIL: N hits (threshold T)` and returns 0 or 1.
- `scan_section(title)` — prints a section header for readability.

Existing 4 scripts and new 2 scripts (`scan_catalog_only.sh` for
ADR-0018, `scan_panic_audit.sh` for ADR-0019) source the lib.

### Part 2 — `test/run_all.sh` run_step pattern

The runner exposes:

- `run_step <name> <command> [optional]` — runs a step, captures
  pass / fail / timing, prints `[pass] name (Ns)` or `[fail]
  name (exit N)`. The `optional` flag marks the step as
  non-blocking (recorded but does not fail the overall run).
- `--list` — lists step names without running.
- `--skip <name>[,<name>]` — skips named steps.
- `--only <name>[,<name>]` — runs only named steps.
- `print_summary` — final tally (passed / failed / failed
  optional) and exits non-zero if any non-optional step failed.

Step name convention: `<area>_<gate>` (`zig_build_test`,
`zone_check`, `e2e_phase3_cli`, `scan_catalog_only`). The naming
is grep-friendly and matches the Layer taxonomy from ADR-0021
(`unit` → Layer 1, `e2e_*` → Layer 2, `diff` → Layer 3,
`bench_quick` → Layer 4).

### Naming alignment

- `scripts/check_compat_tiers_sync.sh` → keeps existing name
  (legacy, sourced from `scan_lib.sh` after refactor).
- `scripts/check_no_op_stub.sh` → same.
- `scripts/check_tier_d_error_msg.sh` → same.
- `scripts/file_size_check.sh` → same.
- `scripts/scan_catalog_only.sh` (new, ADR-0018) — uses
  `scan_lib.sh`.
- `scripts/scan_panic_audit.sh` (new, ADR-0019) — uses
  `scan_lib.sh`.

The `check_` prefix is grandfathered for the four existing
scripts to avoid churn; new scans use `scan_` per Pollaroid
naming.

## Alternatives considered

### Alternative A — Keep scans independent

- **Sketch**: each check_*.sh has its own helpers.
- **Why rejected**: divergence already started; the rename
  `tier_d_form` → `tier_d_<form>` in ADR-0018 amendment 2 had to
  touch 4 scripts because the lookup logic was duplicated.

### Alternative B — Make every check a Zig program

- **Sketch**: `scripts/scan_lib.zig` and per-scan Zig binaries.
- **Why rejected**: bash + grep handles the surface in ~150
  lines. A Zig program adds build dependency, executable juggling,
  and gives no expressive gain.

### Alternative C — Use `pre-commit` framework

- **Sketch**: adopt the `pre-commit` tool (Python-based).
- **Why rejected**: adds a runtime dependency; cw v1 uses
  `.githooks/` + bash already.

## Consequences

- **Positive**: shared helpers across 6 scan scripts. Consistent
  output format (`[<gate>] PASS/FAIL: N hits`). New scans land
  with ~10 lines of bash on top of the lib. `test/run_all.sh`
  gains skip / only / summary without a Zig rewrite.
- **Negative**: refactoring the 4 existing scripts has a small
  cost (one-time grep replacement). Bounded.
- **Neutral / follow-ups**: Phase 5+ flips
  `$CLJW_SCAN_MODE=gate` (default at that phase boundary) so
  scan scripts begin to gate. Each script's
  `informational → gate` transition is decided per scan
  (ADR-0013 / 0016 / 0018 / 0019 etc. carry the phase).

## Affected files

Phase 4 entry (this commit batch):

- `scripts/scan_lib.sh` (new)
- `scripts/scan_catalog_only.sh` (new, ADR-0018 enforcement)
- `scripts/scan_panic_audit.sh` (new, ADR-0019 enforcement)
- `test/run_all.sh` (refactor: run_step pattern + summary)

Phase 5 entry (deferred — these scripts already work in standalone
informational mode, and their output format alignment with
`scan_lib.sh` is a low-priority polish that can ride with the
informational-to-gate mode flip at Phase 5):

- `scripts/check_compat_tiers_sync.sh` (refactor: source lib)
- `scripts/check_no_op_stub.sh` (refactor: source lib)
- `scripts/check_tier_d_error_msg.sh` (refactor: source lib)
- `scripts/file_size_check.sh` (refactor: source lib)

## References

- ADR-0013 (Tier D — check_tier_d_error_msg consumer)
- ADR-0016 (File size — file_size_check consumer)
- ADR-0018 (Error catalog — scan_catalog_only consumer)
- ADR-0019 (Crash policy — scan_panic_audit consumer)
- zwasm v1 `run_step` pattern (precedent)
- Pollaroid ADR-0049 / 0051 / 0089 sister scanner pattern
  (precedent)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
