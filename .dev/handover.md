# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `1d0b9d1` (Phase 13 DONE + D-082 moved to Discharged
  table; see `git log` for exact HEAD).
- **First commit on resume MUST be**: §9.16 row 14.0 boundary
  follow-ups — Step 0.5 debt sweep of ~14 stale-Phase Active rows
  (D-008 / D-014a / D-014b / D-017 / D-022 / D-023 / D-024 / D-025
  / D-026 / D-030 / D-033 / D-045 / D-048 / D-069 / D-070 / D-079);
  `Opcode.isPositionRelative()` extraction in opcode.zig (parallel
  to `isPurePush`, compile-time safety for the dual half of the
  peephole contract — simplify-arm [should]); peephole.zig
  defensive negative-offset + i16-overflow comments (security-arm
  [low]).
- **Forbidden this session**: pulling the v0.1.0 release tag (row
  14.14) forward without all 14.0-14.13 closed. Phase 14 is the
  v0.1.0 milestone — release rides exit smoke + activation only.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009; F-008
zwasm v2 spec review is load-bearing for row 14.12) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.16 Phase 14 task list
→ `.dev/debt.md` Step 0.5 sweep (Phase 14 entry debts listed in
§9.16: D-014a / D-014b / D-066 / D-079 / D-097 / D-098 / D-099 /
D-100 / D-102 / D-104 / D-036 / D-037 / D-038) → ADR-0015 (REPL
/ nREPL wiring + amendment 2 F140-F144 table) · ADR-0021 (test
taxonomy / Conformance gate) · ADR-0034 (cljw build / Tier 0 /
EDN / decode — D-100 substantive cycles).

## Current state

Phase 14 (v0.1.0 milestone) IN-PROGRESS on `cw-from-scratch`.
Phase 13 closed DONE at `797cb1a`. Gate green at HEAD: Mac 76/76
+ OrbStack Ubuntu x86_64 75/75.

This session ran Phase 13 entry through DONE: §9.15 opened, Step
0.5 swept (D-014c / D-014d / D-027 / D-029 / D-040 Discharged),
ADR-0010 amendment 3 + ADR-0047 minted (with Devil's-advocate
forks), rows 13.1-13.5 implemented (Ref + read-only deref +
peephole pure-push+op_pop elision + 5-canonical fib_recursive
verified at 83% of v0 24C.10 + Phase 13 exit smoke). D-101 /
D-102 / D-103 / D-104 minted as Phase 14+ follow-ups.

## Active task — §9.16 row 14.0

Phase 13→14 boundary review chain produced [block] / [should] /
[low] findings already absorbed where mechanical (D-082 moved to
Discharged at `1d0b9d1`; handover refreshed in this commit). The
remaining row-14.0 work is: ~14 stale-Phase Active rows (Step 0.5
re-target / Discharge sweep), `Opcode.isPositionRelative()`
extraction, and the two peephole defensive comments.

## Guardrail refresh history

Phase 13→14 boundary (2026-05-28): §9.16 expanded inline (15 rows,
v0.1.0 milestone); D-082 moved Active → Discharged. Phase 13
landmarks (2026-05-28): ADR-0010 amendment 3 + ADR-0047 minted via
Devil's-advocate forks; D-014c / D-014d / D-027 / D-029 / D-040
Discharged; D-101 / D-102 / D-103 / D-104 minted Active.
