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

- **Phase**: **Phase 6 IN-PROGRESS (opened 2026-05-24)** —
  §9.7 (Phase 5) closed; §9.8 expanded with 15 rows (6.0 →
  6.15). 6.1 = analyzer.zig split (deferred 5.13). Cluster
  work: capability foundations (uuid/clock/random/regex/time/
  file_io), first Java host wave, Clojure stdlib companions.
- **Branch**: `cw-from-scratch`. HEAD advances per boundary
  sync commit on top of b876ee4 (5.13 deferral).
- **Gate**: Mac 16/16 + OrbStack Ubuntu x86_64 15/15 green
  (e2e_phase5_exit added at 5.16).
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

## Active task — §9.8.2 runtime/uuid.zig + lang/primitive/uuid.zig + runtime/java/util/UUID.zig

§9.8.1 (analyzer split) complete at `149371f`. 5 sub-files all
under A6 1000-line cap. D-030 discharged.

Next: **6.2** — First F-009 multi-zone exercise. Land UUID in
three zones simultaneously:

1. `runtime/uuid.zig` (impl) — `randomBytes() [16]u8` + format
   v4 helpers. Backed by `std.crypto.random` (via
   `runtime/crypto/secure_random.zig` if that file already
   exists; otherwise inline here, factor out at 6.4).
2. `lang/primitive/uuid.zig` — `clojure.core/random-uuid` (no
   args, returns String of the UUID v4 form) + `parse-uuid`
   (validates a 36-char string).
3. `runtime/java/util/UUID.zig` — Java surface with
   `randomUUID` / `fromString` / `toString` etc. Marker
   docstring per `.claude/rules/feature_name_consistency.md`
   (`Backend: impl-only` / `Impl deps: uuid` / `Clojure peer:
   clojure.core/random-uuid`).
4. `compat_tiers.yaml` entry migrated to the ADR-0029 D5
   extended schema (first one — G3 gate validates).

**Step 0**: F-005/F-009 verbatim; ADR-0029 D1+D4+D5; cw v0
`src/lang/interop/classes/uuid.zig` (221 lines) for prior-art
on UUID v4 format; clojure.lang.Numbers for random-uuid
semantics. Fork `general-purpose` survey if useful, but the
scope is small.

**Open hazards**: (a) UUID v4 needs `std.crypto.random.bytes`;
direct std.crypto call for Phase 6 (io_interface abstraction
for random at Phase 14+). (b) compat_tiers.yaml: only UUID's
entry migrates to the new schema in 6.2; other 39 entries stay
legacy until their owning task touches them.

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
