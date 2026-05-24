# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Next 6 files to read (cold-start order)

1. `.dev/handover.md` (this file) — current state + active task.
2. `CLAUDE.md` § Project spirit + § Autonomous Workflow (Step 0 → 7)
   + § The only stop (single condition: user explicit stop) +
   § Smell triggers are interrupts, not stops.
3. `.dev/project_facts.md` — user-declared invariants F-001..F-008
   (treat as project law; never amend without user direction).
4. `.dev/principle.md` — Bad Smell catalogue (16 entries) +
   Structural imagination phase + Devil's-advocate subagent
   mandate at depth ≥ 2 (F-NNN envelope).
5. `.dev/structure_plan.md` — anticipated directory tree
   Phase 5-20 (decree entries vs imagination entries).
6. `.dev/ROADMAP.md` — find IN-PROGRESS phase in §9; take the
   first `[ ]` row. At a Phase entry, load each ADR (incl.
   Revision history) / D-NNN row / F-NNN listed in the §9.<N>
   placeholder's Entry ADRs / Entry debts / Entry facts lines.

## Current state

- **Phase**: Phase 4 IN-PROGRESS. §9.6 critical-path closed
  (4.0–4.12 done). Cleanup wave: 4.13–4.25 done. Error-system
  migration: 4.26.a (Code rename) + 4.26.b (tier_d_form split) +
  4.26.c (Error → ClojureWasmError) + 4.26.d region 1/6 (reader,
  21 sites) done. Remaining 4.26.d regions: analyzer (38) /
  tree_walk (15) / macro_transforms (14) / primitive (7) /
  error.zig helpers (11). Then 4.26.e / 4.26.f close §9.6.
- **Branch**: `cw-from-scratch` (long-lived; push after gate
  green; never push to `main`).
- **Gate**: Mac 12/12 + OrbStack Ubuntu x86_64 11/11 green at
  HEAD.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.6 / 4.26.d region 2 (analyzer, 38 sites)

`src/eval/analyzer.zig` has 38 `error_mod.setErrorFmt(...)` sites
that rotate to `error_catalog.raise(.code, loc, args)`. Catalog
needs ~25-30 new Code variants. Recommended grouping for the
single analyzer commit:

- cluster a: top-level resolution (lines ~224 / 225 / 277 / 279 /
  280 / 301)
- cluster b: def + if + quote (~412–505)
- cluster c: fn* (~534–556)
- cluster d: let* + loop* binding (~629–722)
- cluster e: recur + throw (~757–796)
- cluster f: try + catch (~855–906)

**Catalog amendment to surface during region 2**: existing
`let_bindings_not_vector` / `let_bindings_arity_odd` (4.26.a)
generalise to `bindings_not_vector` / `bindings_arity_odd` with a
`.form` slot so loop* / let* share one Code each. Depth-1
commit-body note within the analyzer region.

**Retrievable identifiers**: ROADMAP §9.6 4.26.d row text;
ADR-0018 amendment 2 (a). After 4.26.d completes, 4.26.e
(`@panic` / `unreachable` audit per ADR-0019) and 4.26.f (main
top-level catch wiring) close §9.6 and Phase 4.

## Open questions / blockers

None testable from inside the loop. Recall triggers + follow-up
candidates live in [`debt.md`](./debt.md) (rows D-005 through
D-040). Step 0.5 debt sweep walks them at resume; pay attention
to D-027 / D-028 (Phase 5 structural surgery) and D-040 (Phase 7
MethodEntry naming).

## Guardrail refresh history (condensed)

User-directed guardrail evolution 2026-05-23 / -24:

- Wave 1-2 (2026-05-23): project spirit (finished-form wins),
  Bad Smell catalogue grew Smallest-diff / Reservation-as-bias /
  Progress-pressure smells, Structural imagination phase, and
  ten D-027..D-036 structural-foresight debts for Phase 5-20.
- Wave 3 (2026-05-23): root-cause hardening after the long-context
  research (`private/notes/llm_long_context_research.md`) —
  `.dev/project_facts.md` (F-NNN, project law),
  `scripts/check_smell_audit.sh` PreToolUse hook.
- Wave 4-5 (2026-05-24): F-004 NaN-box 64-slot / F-005 numeric
  tower / F-006 GC strategy / F-007 chapter cadence dormant /
  F-008 zwasm v2 spec review; `.dev/structure_plan.md` Phase 5-20
  tree.
- Wave 6 (2026-05-24): F-NNN hardening — preamble = project law,
  5-level priority chain, Devil's-advocate F-NNN envelope ban,
  `scripts/check_facts_immutable.sh` PreToolUse hook. Silent
  default-shift smell added to principle.md.
- Wave 7 (2026-05-24): stop-list narrowed to the single condition
  "user explicit stop"; smell triggers are interrupts (in-flight
  surgery), build/test failures are Active-task items, and
  Phase / region / task / commit boundaries roll into the next
  unit of work. Smell-cluster / physical-block / ADR-phase-mode
  stop wording removed across CLAUDE.md / principle.md /
  continue SKILL.md / handover_framing.md / extended_challenge.md.
