# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `.dev/ROADMAP.md` — find IN-PROGRESS phase in §9, take the
   first `[ ]` row in §9.<N>.
3. The most recent `docs/ja/learn_clojurewasm/NNNN_*.md` chapter —
   to recover the conceptual baseline for the active phase.

## Current state

- **Phase**: Phase 4 IN-PROGRESS. §9.6 cluster A done
  (tasks 4.1 / 4.2 / 4.3); critical-path: 4.0 / 4.0a / 4.4 / 4.5
  / 4.6 / 4.7 / 4.8 done.
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived;
  push free after gate green; never push to `main`).
- **Last commit**: see `git log -1` (compute on resume — the
  resume procedure reads it directly).
- **Gate**: Mac (9/9) + OrbStack Ubuntu x86_64 (8/8) green at
  HEAD. 🔒 fresh OrbStack run due at Phase 4 close.
- **Last paired chapter commit**: `cc46a48` (chapter 0020 —
  Phase 3 closure, covers §9.5 / 3.8–3.14).
- **Unpaired source SHAs**: `git log cc46a48..HEAD --oneline -- src/`
  (compute on resume; chapter pairing decision is per the
  `code_learning_doc` skill's two-cadence rule).

## Active task — §9.6 / 4.9

Run the full unit-test suite under both backends. Phase-4 entry
already runs `zig build test` (default tree-walk) and `zig build
test -Dbackend=vm` cleanly. 4.9 expands this to: (a) any
TreeWalk-only test (e.g., heap collection deinit-ordering
specifics) is moved into a `runtime`-zone test that does not
depend on backend, or duplicated with a backend-specific
`test "...vm only"` qualifier; (b) `test/run_all.sh` learns a
`--backend vm` mode that wires `zig build test -Dbackend=vm` in
addition to the default. Both gate runs (Mac + Ubuntu) must be
green under both backends before close.

**Retrievable identifiers**:

- ROADMAP §9.6 task 4.9 + dependency-graph at §9.6.x.
- ADR-0005 (dual backend strategy), ADR-0022 (differential).
- `src/eval/driver.zig` (4.8) — the comptime backend switch.
  `installVTable` + `evalForm` route per `build_options.backend`.
- `test/run_all.sh` — the test runner. Add a new step (or
  argument) that runs `zig build test -Dbackend=vm` after the
  default tree-walk gate.

## Open questions / blockers

None. External blockers, recall triggers, and follow-up
candidates live in [`debt.md`](./debt.md) (rows `D-005` through
`D-026`). The resume Step 0.5 debt sweep walks them.
