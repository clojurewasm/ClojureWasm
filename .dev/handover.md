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

- **Phase**: **Phase 5 IN-PROGRESS** — §9.7 rows 5.0 / 5.1 / 5.2 `[x]`;
  5.3 IN-PROGRESS through 5.3.b.4. 5.1 paired ADR cluster ADR-0027
  + ADR-0028 Accepted (amendments 1/2/3 landed for §1 bit-layout
  corrections). 5.2 split-then-widen (5e8d035 + 9fe4e20). 5.3
  sub-commits: 5.3.a skeleton (a25b1b9) + 5.3.b.1 alloc body
  (0ed5d2c) + 5.3.b.2 mark phase (839f859) + 5.3.c.1 sweep direct
  (437cd53) + 5.3.c.2 free-pool push/pop + min-16 alloc (7567e31)
  + 5.3.b.4 comptime check (1e1eaf4). 14 rows remain (5.3 close,
  5.4–5.16). Phase 4 DONE.
- **Branch**: `cw-from-scratch`. HEAD = 1e1eaf4.
- **Gate**: Mac 13/13 + OrbStack Ubuntu x86_64 12/12 green.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.7.4 / 5.3 continuation: roots + collect + alloc migration

Remaining sub-commits to close row 5.3:
- **5.3.b.3**: wire 10 root walkers into `root_set.zig` per ADR-0028
  §5. Survey at `private/notes/phase5-5.3.b.3-survey.md` (subagent
  output pending).
- **5.3.b.5**: wire `GcHeap.collect()` = mark roots + sweep +
  adaptive threshold (`max(default, last_live_bytes * 2)`); blocks
  on 5.3.b.3 (roots needed for collect to be safe).
- **5.3.d**: migrate Phase 1-4 alloc sites (string / Cons / ex_info
  / Namespace / Var / Keyword) `gpa.create` → `gc.alloc`; flip
  `Flags.marked` → `gc_and_lock.mark`; remove `gc_*_not_supported`
  Codes per ADR-0017 a1; flip auto-trigger on in alloc.

**Step 0 reading** (for 5.3.b.3): `private/notes/phase5-5.3.b.3-survey.md`
+ ADR-0028 §5 root table + ADR-0017 a1 rewrite scope +
`phase5-skeleton-audit.md` §"binding_stack.zig REVERTED".

**Open hazards**: (a) auto-trigger of collect() must wait until
5.3.b.3; (b) `ProtocolFn` / `MultiFn` caches may not exist in cw v1
yet — survey confirms, walker for row 5 may declare `null`
placeholder; (c) Runtime field `gc: *GcHeap` lands at 5.3.d.

## Open questions / blockers

None testable from inside the loop. Recall triggers + follow-up
candidates live in [`debt.md`](./debt.md) (rows D-005 through
D-043). Step 0.5 debt sweep walks them at resume; pay attention
to D-008 / D-014a / D-014b / D-017 / D-030 (other Phase-5-target
rows that 5.2-5.16 will land), D-040 (Phase 7 MethodEntry
naming — do not touch in Phase 5), D-043 (anonymous slot
reserves for Phase 7 entry to revisit).

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
- Wave 7 (2026-05-24): stop-list narrowed to "user explicit stop"
  only; smell triggers are interrupts (in-flight surgery),
  build/test failures are Active-task items, Phase / region /
  task / commit boundaries roll into the next unit of work.
