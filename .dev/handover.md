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
  (tasks 4.1 / 4.2 / 4.3); critical-path entry done (4.0 / 4.0a).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived;
  push free after gate green; never push to `main`).
- **Last commit**: `b09b54e` (autonomous-workflow spec revision —
  closed 3-condition stop list, dropped Step 8 compact gate).
- **Gate**: Mac (9/9) + OrbStack Ubuntu x86_64 (8/8) green at
  `b09b54e`. 🔒 fresh OrbStack run due at Phase 4 close.
- **Last paired chapter commit**: `cc46a48` (chapter 0020 —
  Phase 3 closure, covers §9.5 / 3.8–3.14).
- **Unpaired source SHAs**: `git log cc46a48..HEAD --oneline -- src/`
  (compute on resume; chapter pairing decision is per the
  `code_learning_doc` skill's two-cadence rule).

## Active task — §9.6 / 4.4

`src/eval/backend/vm/opcode.zig` (new file) — Opcode enum
(`op_const`, `op_load_local`, `op_store_local`, `op_def`,
`op_get_var`, `op_jump`, `op_jump_if_false`, `op_call`, `op_ret`,
`op_pop`, `op_dup`, `op_throw`, `op_make_fn`, `op_recur`,
`op_invoke_builtin`) + `BytecodeChunk` struct + per-chunk constant
pool. Critical-path VM start point — 4.4 → 4.5 (compiler) → 4.6
(dispatch loop) → 4.7 (Phase-3 special forms) → … → 4.12 (exit
smoke).

**Retrievable identifiers**:

- ROADMAP §9.6 task 4.4 + the dependency-graph section at §9.6.x.
- ADR-0005 (dual backend strategy), ADR-0022 (differential
  wiring), ADR-0024 (scan framework + run_step).
- New file path: `src/eval/backend/vm/opcode.zig`.

## Next Phase Queue (Phase 5 entry — promote when §9.6 closes)

- HAMT persistent vector / hashmap / hashset (per ADR-0007 +
  `private/JVM_TO_ZIG.md` §10).
- Mark-sweep GC `GcHeap.collect` + roots + threshold trigger (per
  ADR-0017; activates skeletons from task 4.0a flip of
  `phase_at_least_5`).
- Object header bit helpers `cmpxchgLockBits` / mark-bit ops (per
  ADR-0009 + debt `D-020`).
- `LazySeq.force()` + trampoline (per `JVM_TO_ZIG.md` §9; activates
  task 4.24 skeleton).
- BigInt arithmetic + promotion (per ADR-0012; activates task
  4.23 skeleton).
- `TypeDescriptor.lookupMethod` / `register` / `new`; deftype /
  defrecord / reify activation (per ADR-0007 + tasks 4.17 / 4.21).
- Flip `build_options.phase_at_least_5 = true` (per ADR-0023 +
  task 4.0a).

## Open questions / blockers

None. External blockers, recall triggers, and follow-up
candidates live in [`debt.md`](./debt.md) (rows `D-005` through
`D-026`). The resume Step 0.5 debt sweep walks them.
