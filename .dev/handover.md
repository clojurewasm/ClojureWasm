# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (Phase 8 close commits — row 8.5 cycle 1-3,
  row 8.6 cycle 1-4, row 8.7 exit smoke).
- **First commit on resume MUST be**: §9.11 Phase 9 task list
  open commit. Run the Phase 8 → 9 boundary review chain
  (`audit_scaffolding` + built-in `simplify` on the Phase 8 diff
  + built-in `security-review` on unpushed commits — parallel
  fan-out), then expand the §9.11 Phase 9 placeholder inline
  (mirror §9.10 structure) and commit alone with
  `git commit -m "roadmap: open Phase 9 task list"`.
- **Forbidden this session**: re-shaping `clojure.set/map-invert`
  back to persistent-reduce (D-074 cycle 3 flipped it to the JVM
  transient form on 2026-05-27).

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.11 placeholder →
`.dev/debt.md` Step 0.5 sweep (D-045 HAMT still blocking
TransientHashMap; D-085 keyword-as-fn callable; D-086 defrecord
`__extmap` overflow).

## Current state

Phase 8 **DONE** — §9.10 rows 8.0..8.7 all [x]. Phase 9 (modules
/ json / csv / edn) is the next PENDING phase per the §9 master
table. Branch `cw-from-scratch`. Gate green: Mac 64/64 +
OrbStack Ubuntu x86_64 63/63. Highlights of Phase 8:

- bench gate active in informational mode (1.2x ceiling wired,
  Mac/Linux locks seeded; row 8.2 + 8.3)
- `cljw --compare` dual-backend differential flag (row 8.4)
- transient surface complete — 7 primitives + 2 catalog Codes +
  3 TransientFoo structs (row 8.5)
- D-089 retro-audit complete — 12 collection primitives now
  user-`extend-type`-able (row 8.6)

## Active task — §9.11 Phase 9 entry

Phase 9 placeholder reads "Protocols + Multimethods + Interop
deep module" but the §9.11 entry note already flags scope
reconciliation: protocols + multimethods landed at Phase 7,
host stdlib first wave landed at Phase 6, so the Phase 9 entry
owner must rewrite the Deliverables line to match the actual
remaining scope (external Clojure modules — `clojure.data.json` /
`.csv` / `.edn` / `tools.cli`) before opening the task table.
D-034 (`modules/` top-level structure decision) is the Entry
debt to resolve at Phase 9 entry.

## Extended challenge (per `.claude/rules/extended_challenge.md`)

Not applicable — the loop is rolling through Phase 8 close into
Phase 9 open; no user-requested stop is in flight.

## Guardrail refresh history

Phase 8 landmarks (closed 2026-05-27): ADR-0044 (bench/history.yaml
schema; minted as ADR-0027 at row 8.2 then renumbered at the Phase
8 → 9 audit, slot-0027 was already held by the NaN-box ADR) +
row 8.1 `src/app/` split + row 8.3 1.2x regression gate
+ row 8.4 `--compare` CLI + row 8.5 transient surface + row 8.6
D-089 retro-audit (6 new protocols: ISeq / ILookup / Indexed /
Associative / IPersistentMap / IPersistentSet) + row 8.7 exit
smoke (`test/e2e/phase8_exit_smoke.sh`).
