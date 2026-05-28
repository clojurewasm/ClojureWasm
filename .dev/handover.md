# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: ≈ `8826fde` (Phase 14 rows 14.0-14.3 closed + 14.4/14.5/14.6
  probed with refined debt barriers; see `git log` for exact HEAD).
- **First commit on resume MUST be**: a focused **row 14.4 (D-014a
  numeric tower) implementation cycle** — the probe surfaced 3 precise
  gaps already enumerated in D-014a's barrier (Value.initInteger
  large-Long → BigInt promotion, reader Ratio literal arm, tokenizer
  BigDecimal `M`-suffix recognition). All three are testable; pick the
  simplest first or batch them per a focused multi-file plan. Row
  14.5 (D-014b ex-info `:type` dispatch) and row 14.6 (D-099
  defmacro) are similarly multi-cycle with refined barriers — pick
  whichever the user / Step 0 survey blesses as the next strongest
  lever for v0.1.0.
- **Forbidden this session**: pulling the v0.1.0 release tag (row
  14.14) forward without all 14.4-14.13 closed.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009; F-005
numeric tower spec governs row 14.4) → `.dev/principle.md` →
`.dev/ROADMAP.md` §9.16 Phase 14 task list (rows 14.0-14.3 [x];
14.4 onwards [ ]) → `.dev/debt.md` Phase-14-entry debts (refined
barriers from this session: D-014a / D-014b / D-099 each name the
specific seams); other live debts (D-066 / D-098 / D-100 / D-102 /
D-104 / D-105 / D-106 / D-036 / D-037 / D-038 + F-008).

## Current state

Phase 14 (v0.1.0 milestone) IN-PROGRESS on `cw-from-scratch`. Phase
13 closed DONE at `797cb1a`. Gate green at HEAD: Mac 76/76 + OrbStack
Ubuntu x86_64 75/75.

This session ran Phase 12→13 boundary + full Phase 13 open-to-close
(ADR-0010 a3 + ADR-0047 with DA forks; Ref/deref + peephole + 5-
canonical bench probe) + Phase 14 open with 14.0-14.3 closed
(`isPositionRelative` + Step 0.5 debt sweep + installAll aggregator
discharging D-079 + 7 new surface files for D-097 second + third
waves). Rows 14.4 / 14.5 / 14.6 probed and their debt-row barriers
refined with precise discharge anchors; D-105 / D-106 minted for
deferred backing impls (runtime/time, runtime/net, runtime/crypto).

## Active task — §9.16 row 14.4 (or row 14.5 / 14.6 — owner picks)

Row 14.4 (D-014a numeric tower) is the most observable next win for
v0.1.0 — the 3 probe-found gaps each have direct test predicates
(`(* Long/MAX_VALUE 2)` → BigInt; `(+ 1/3 1/6)` parses + folds;
`1.5M` parses as BigDecimal). Row 14.5 (catch-by-`:type`) and 14.6
(user defmacro) each unblock test-corpus surfaces that the v0.1.0
release will exercise. The Step 0 survey for whichever row the next
cycle picks should anchor on the refined debt-row barrier.

## Guardrail refresh history

Phase 13→14 boundary (2026-05-28): §9.16 expanded inline (15 rows);
D-082 → Discharged table; D-008/D-017/D-026/D-030/D-069/D-070
Discharged + D-022/D-023/D-024/D-025/D-033/D-045/D-048 Opportunistic
+ D-014a/D-014b/D-079 promoted to Phase 14 rows. Phase 13 landmarks
(2026-05-28): ADR-0010 amendment 3 + ADR-0047 minted; D-014c/D-014d/
D-027/D-029/D-040/D-079/D-097 Discharged; D-101-D-106 minted Active.
