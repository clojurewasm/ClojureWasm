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

- **Phase**: **Phase 5 IN-PROGRESS** — §9.7 rows 5.0–5.8 `[x]`,
  5.9.a `[x]` (BigInt extern-struct migration; 5.3.d.9 deferral
  resolved at 7e2ef17). 5.9.b/c/d (Ratio + BigDecimal + arithmetic)
  remain; 5.10–5.16 also remain (7 row.subset units total).
- **Branch**: `cw-from-scratch`. HEAD = 7e2ef17.
- **Gate**: Mac 13/13 + OrbStack Ubuntu x86_64 12/12 green
  (verified both gates' exit codes explicitly at HEAD).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Stopped — user requested

User instruction (2026-05-24): 「きりが良くなったら止めて
（ユーザー介入）」. Stop honoured at HEAD = 7e2ef17 — 5.9.a (BigInt
extern struct migration) landed + verified green on both gates +
D-047 records the Zig 0.16 setString Linux platform bug. Next
session resumes at §9.7.10 / 5.9.b (Ratio implementation).

Extended-challenge items captured per `.claude/rules/extended_challenge.md`
in `private/notes/phase5-5.9.md` (Alt hypothesis / Next experiment /
Explicit blocker).

## Active task at resume — §9.7.10 / 5.9.b Ratio (then .c BigDecimal, .d arithmetic)

5.9.a (7e2ef17) shipped BigInt extern + `*Managed` wrapper +
finaliser + `allocFromI64` / `allocFromManaged`. Next: 5.9.b Ratio
`(*Managed, *Managed)` gcd-simplified; 5.9.c BigDecimal
`(*Managed unscaled, i32 scale)`; 5.9.d arithmetic
(`compare`/`+`/`-`/`*`/`/`) across the tower.

**Step 0**: F-005 verbatim; ADR-0017; cw v0 collections.zig
Ratio/BigDecimal; clojure JVM Numbers.java. Fork `general-purpose`
survey subagent per `private/notes/phase5-5.9.md` Next experiment.

**Process discipline**: Step 5 — always verify BOTH gates' exit
codes explicitly (`echo "exit=$?"` + `grep "failed:[[:space:]]+0"`)
before commit. 94d228b skipped this and pushed despite Linux
failure; 7e2ef17 rolled forward. Add gate-verification hook or
script-level enforcement.

**Open hazards**: (a) Ratio `(*Managed, *Managed)` + gcd via
`std.math.big.int.gcd` (verify Linux platform soundness post-D-047);
(b) auto-promotion paths land at 5.10 (separate row).

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
