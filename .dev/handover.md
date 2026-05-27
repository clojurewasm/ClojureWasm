# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Stopped — user requested

User instruction (2026-05-27): 「きりがよくなったら、止めてください」
(= "stop when you reach a good break point"). Phase 12 just
closed (DONE-PARTIAL) at commit `e99cdbd`; Phase 13 not yet
opened. Resume at §9.15.

## Resume contract

- **HEAD**: `e99cdbd` (Phase 12 partial close — rows 12.3-12.5
  enumeration-only per D-100).
- **First commit on resume MUST be**: §9.15 Phase 13 task list
  open commit. Run the Phase 12 → 13 boundary review chain
  (`audit_scaffolding` + simplify-on-Phase-12-diff +
  security-review-on-unpushed — parallel fan-out), then expand
  the §9.15 Phase 13 placeholder inline (mirror §9.14 structure)
  and commit alone with
  `git commit -m "roadmap: open Phase 13 task list"`.
- **Forbidden this session**: re-opening Phase 12 D-100 sub-
  deliverables (cljw build CLI / render-error decoder / cold-
  start bench) inside Phase 13 — Phase 13 is STM (`Ref` / `TVal`
  data structures) + VM optimisation peephole.zig + 5-bench
  parity per cw v0 24C.10. D-100 cycles ride dedicated sessions.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.15 placeholder →
`.dev/debt.md` Step 0.5 sweep (D-045 HAMT; D-080 `=` over
non-numbers; D-096 println output reach; D-097 second-wave host
stdlib; D-098 ns directive surface; D-099 user defmacro;
**D-100** Phase 12 substantive deliverables (a)..(e)) →
per-task note at `private/notes/phase12-partial-close.md`
(extended-challenge entries for the resume's first cycle).

## Current state

This session ran Phase 7 close through Phase 12 partial-close on
branch `cw-from-scratch`. ~30 commits across the boundary chain.
Gate green at HEAD: Mac 75/75 + OrbStack Ubuntu x86_64 74/74.

Highlights (Phase 8 → 12):
- Phase 8 (transients + bench gate + --compare + D-089 retro-audit)
- Phase 9 (modules layer + edn/json/csv/cli + ADR-0044 collision repair)
- Phase 10 (pprint + host stdlib enumeration + D-095/D-096/D-097/D-098)
- Phase 11 (clojure.test + 13 ported upstream tests + Tier A gate active)
- Phase 12 partial (ADR-0034 rediscovery + bytecode serializer skeleton + D-100)

## Active task — §9.15 Phase 13 entry

Phase 13 placeholder per §9 master table: "VM optimisation:
peephole.zig + STM Ref/TVal data structures + five canonical
benchmarks within 110% of cw v0 24C.10". Entry ADRs: 0010 (STM
— Ref / TVal data structures). Reference `private/JVM_TO_ZIG.md`
§5 (STM Zig API). Phase 13 entry owner expands inline.

## Extended challenge (per `.claude/rules/extended_challenge.md`)

Recorded in `private/notes/phase12-partial-close.md` per the rule
(alt hypothesis / next experiment / explicit blocker).

## Guardrail refresh history

Phase 8-12 landmarks (closed 2026-05-27): ADR-0044 (bench schema
renumbered from ADR-0027 collision), ADR-0045 (§9 row 9
reconciliation), ADR-0046 (skip taxonomy), ADR-0034 rediscovery;
D-074 / D-007 / D-034 / D-089 Discharged; D-095 / D-096 / D-097
/ D-098 / D-099 / D-100 minted Active.
