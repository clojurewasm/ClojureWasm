# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `3fec496` (Phase 13 opened + Step 0.5 sweep; see
  `git log` for exact HEAD).
- **First commit on resume MUST be**: §9.15 row 13.1 — STM `Ref` /
  `TVal` data structures land fresh in `src/runtime/stm/ref.zig`
  (no Phase-4 skeleton exists; F-004 Group C `ref` NaN-box slot +
  GC trace + `(ref init)` constructor). Entry ADR 0010 §"Phases"
  (Phase 13 = data structures only; removes no STM staged Codes).
- **Forbidden this session**: pulling STM commit-loop behaviour
  (`dosync` / `alter` / `commute` / `ensure` / `ref-set` commit +
  retry + barge — D-009 / D-010 / D-012 / D-013 / D-020 / D-046)
  forward; that is Phase 14-15. D-100 Phase 12 substantive
  deliverables (cljw build CLI / render-error decoder / cold-start
  bench) ride dedicated sessions.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.15 Phase 13 task list →
`.dev/debt.md` Step 0.5 sweep (D-045 HAMT; D-096 println output
reach; D-097 second-wave host stdlib; D-098 ns directive surface;
D-099 user defmacro; D-100 Phase 12 deliverables; D-101 empty-list
deviation) → ADR-0010 (STM phase split).

## Current state

Phase 13 (VM optimisation peephole.zig + STM Ref/TVal) IN-PROGRESS
on `cw-from-scratch`. Phase 12 closed DONE-PARTIAL. Gate green:
Mac 75/75 + OrbStack Ubuntu x86_64 74/74.

Row 13.0 boundary work landed: Phase 12→13 review chain (simplify
nice-only, security clean, audit 0-block); Step 0.5 debt sweep
(D-014c / D-014d / D-027 / D-029 / D-040 Discharged; D-041 / D-043
re-targeted; D-101 minted); 3 stale-phase-ref docstrings refreshed;
master-table row 13 STM clause reconciled.

## Active task — §9.15 row 13.1

STM `Ref` / `TVal` data structures + read-only `deref` path (rows
13.1-13.2), then `peephole.zig` optimizer + 5-bench parity (rows
13.3-13.4), exit smoke (13.5). Entry ADR 0010; reference
`private/JVM_TO_ZIG.md` §5 (STM Zig API).

## Guardrail refresh history

Phase 12→13 boundary (2026-05-28): §9.15 expanded inline (6 rows);
debt Step 0.5 sweep cleared 5 closed-phase rows; D-101 minted
(empty-PersistentList deviation). Phase 8-12 landmarks (2026-05-27):
ADR-0044 / 0045 / 0046 + ADR-0034 rediscovery.
