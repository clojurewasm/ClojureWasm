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
  (tasks 4.1 / 4.2 / 4.3); **critical-path closed**: 4.0 / 4.0a /
  4.4 / 4.5 / 4.6 / 4.7 / 4.8 / 4.9 / 4.10 / 4.11 / 4.12 done.
  Cleanup wave in progress: 4.13–4.24 done. Remaining §9.6 rows
  (4.25–4.26.f) — method_table skeleton, error-system migration.
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

## Recent landings (post-stop)

User-directed cleanup landed in 4 commits after the 4c54682 stop:

- 58939f6 — rules: `no_op_stub_forbidden` reframed as
  "Permanent no-op forbidden — transient stubs OK" (skeleton-then-
  rewrite explicitly endorsed).
- bbae2e0 / a0331c1 — ADR-0006 + 0012 amendment 1: NaN-box slots
  `wasm_module` (29) / `wasm_fn` (30) released and re-purposed for
  `big_int` / `ratio`; BigInt dropped its `PHASE4_PLACEHOLDER_TAG`
  smell.
- 302e4ec + (this commit) — ADR-0029 chapter archive boundary:
  `learn_clojurewasm` (20 chapters) + `learn_zig`副読本 moved to
  `docs/ja/archive/`; cadence dormant.

## Active task — §9.6 / 4.25

`src/runtime/dispatch/method_table.zig` — `MethodEntry` struct
(interned symbol + fn ptr) and `CallSite` struct (`last_type` +
`last_method` cache slots) declaration. The `dispatch` function
lands in Phase 7 (per ADR-0008). Phase 4 has only the struct
declarations.

**Retrievable identifiers**:

- ROADMAP §9.6 task 4.25, ADR-0008 (protocol dispatch unify).
- `src/runtime/dispatch.zig` already exists at the same path
  level (Layer 0 vtable). The new file lives in a
  `src/runtime/dispatch/` subdirectory which does not yet exist
  — create it.

## Open questions / blockers

None. External blockers, recall triggers, and follow-up
candidates live in [`debt.md`](./debt.md) (rows `D-005` through
`D-026`). The resume Step 0.5 debt sweep walks them.
