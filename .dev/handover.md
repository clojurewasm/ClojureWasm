# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Next 6 files to read (cold-start order)

1. `.dev/handover.md` (this file) — current state + active task.
2. `CLAUDE.md` § Project spirit + § Autonomous Workflow (Step 0 → 7)
   + § The only stop (single condition: user explicit stop) +
   § Smell triggers are interrupts, not stops.
3. `.dev/project_facts.md` — user-declared invariants F-001..F-009
   (treat as project law; never amend without user direction).
4. `.dev/principle.md` — Bad Smell catalogue (16 entries) +
   Structural imagination phase + Devil's-advocate subagent
   mandate at depth ≥ 2 (F-NNN envelope).
5. `.dev/structure_plan.md` — anticipated directory tree
   Phase 5-20 (decree entries vs imagination entries).
6. `.dev/ROADMAP.md` — Phase 6 IN-PROGRESS (§9.8). Take the
   first `[ ]` row. Phase 6 entry ADRs / Entry debts / Entry
   facts in the §9.8 placeholder.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 rows 6.1, 6.2,
  6.3, 6.4, 6.5.a, 6.7, 6.8 `[x]` (7/15). Remaining:
  6.5.b (LocalDate / LocalDateTime / Duration / ZonedDateTime /
  ZoneId — needs TZ database), 6.6 (regex — engine choice ADR
  open), 6.9-6.12 (clojure.string / set / walk / zip), 6.13
  (compat_tiers schema sweep for remaining ~34 legacy
  entries), 6.14 (Phase 6 exit smoke), 6.15 (phase_at_least_6
  flip).
- **Branch**: `cw-from-scratch`. HEAD ≈ c7f16ca (6.8).
- **Gate**: Mac 16/16 + OrbStack Ubuntu x86_64 15/15 green
  at HEAD.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Phase 5 closing (2026-05-24)

ADR-0029 cluster (Java + cljw surface layout, F-009) + ADR-0030
(defrecord/reify → Phase 7) + 5.9-5.16 landings (numeric tower,
TypeDescriptor, deftype skeleton, exit smoke). Boundary review
chain absorbed audit_scaffolding findings (handover, CLAUDE.md
F-009 enumeration, 3 rules' paths frontmatter, compat_tiers
sync header). D-032 Discharged.

Phase 6.1 (analyzer.zig split per D-030, deferred 5.13) landed
2026-05-24 in 5 commits (1ac8198..149371f); D-030 discharged.

## Active task — §9.8 next: 6.6 (regex with ADR) or 6.9 (clojure.string)

Phase 6 surface scaling validated through 7 rows (6.1, 6.2, 6.3,
6.4, 6.5.a, 6.7, 6.8). 7 Java surfaces on the new schema (UUID /
System / Random / Date / Instant / File / Charset-N/A). G3 gate
clean. Two script convergences uncovered & landed during scaling:
surface-slot exemption (PascalCase ≠ keyword) + underscore-not-
a-splitter (multi-word keywords like `file_io`).

**Resume target options** (largest open work):

1. **6.6 regex** — ADR-level engine choice: custom min vs
   zig-regex 3rd-party vs pcre bind. Devil's-advocate mandatory
   (depth 2-3). After ADR, ~300-500 LOC impl.

2. **6.9 clojure.string** — Tier A ~21 vars. Needs the
   bootstrap to load a second `.clj` file (clojure.string ns
   alongside clojure.core). bootstrap.zig currently hard-codes
   only core.clj load; clojure.string load is a small extension
   that doesn't wait for Phase 10 ns/require.

3. **6.13** — legacy compat_tiers.yaml sweep for the ~34
   remaining flow-style entries. Mechanical bulk diff; should
   run alongside or after 6.6/6.9 land their own entries.

**Recommended next**: 6.6 (regex) is the biggest open
deliverable for the Phase 6 exit criterion (`(re-find #"\d+"
"abc123")` → "123"). Starting with the engine-choice ADR
forces the design moment before any impl code, in line with
F-002.

**Open hazards**: (a) 6.6 regex ADR depth 2-3, Devil's-advocate
fork mandatory. (b) 6.5.b TZ data multi-MB embed — defer.
(c) 6.9 bootstrap.zig extension to load multiple .clj files
needs care (load-order dependencies if clojure.string uses
clojure.core fns at top level).

## Open questions / blockers

None testable from inside the loop. Recall: D-005 / D-014a/b /
D-017 (Phase-5-rolled-into-Phase-6 entries are reviewed by Step
0.5 debt sweep), D-040 (MethodEntry naming → Phase 7),
D-043 (anonymous slot reserves → Phase 7 entry), D-048/049/050
(ADR-0029 post-review follow-ups → Phase 6+).

## Guardrail refresh history (condensed)

- Waves 1-7 (2026-05-23..24): project spirit, Bad Smell
  catalogue, Structural imagination, F-NNN/project_facts
  hardening, Devil's-advocate envelope ban, stop-list narrowed.
- Wave 8 (2026-05-24): ADR-0029 + F-009.
- Wave 9 (2026-05-24): ADR-0030 + Phase 5 closed.
- Wave 10 (2026-05-24): Phase 6.1 analyzer split (D-030
  discharged).
