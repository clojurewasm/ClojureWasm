# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (HEAD refreshes only on Active-task-
  identifier change).
- **First commit on resume MUST be**: open **Phase 6.16.b-4** cycle
  — ADR-0035 (require spec) + D-071 Part 3 (`^:private` enforcement)
  + bootstrap loader topo-sort + circular detection + `:as` / `:refer`
  / `:require :reload` semantics. Devil's-advocate fork mandatory
  (depth-3 ADR). Discharges the **11-marker / 3-yaml-entry
  ns-machinery cluster** (`runtime/eval/in_ns_auto_refer` +
  `runtime/bootstrap/refer_table` + `runtime/eval/bare_in_ns_decl`)
  once `(ns ...)` macro ships. Survey via general-purpose
  subagent first (output `private/notes/phase6-6.16.b-4-survey.md`).
  6.16.b-1/-2/-3 already landed (ddb7203 / 7a915f7 / 6211d8a);
  framework + spike + review-fixes landed
  (1fdc342 / 0fed954 / 89b8fae / 64c697c / ef4f683).
- **Forbidden this session**: (a) `__zig-` namespace prefix path. (b)
  `clojure.X.impl/` sub-ns path. (c) `cljw build --source/--debug/
  --aot` flag path. (d) mixing human + EDN in single stderr stream.
  (e) ABI-level bytecode format commitment. (f) introducing new
  PROVISIONAL markers without same-commit yaml + debt.md sync (the
  hook will physically block — see `.claude/rules/provisional_marker.md`).

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009)
→ `.dev/principle.md` (Bad Smell + Devil's-advocate mandate) →
**`private/notes/clj_vs_zig_split_proposal_v5.md` (placement /
build / error 確定計画 SSOT)** → `.claude/rules/provisional_marker.md`
(marker lifecycle + SSOT triad) → `feature_deps.yaml` (8 provisional
entries / 16 marker sites) → `.dev/structure_plan.md` →
`.dev/ROADMAP.md` §9.8.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 14/24 `[x]` + 6.16.a-0
  … a-3.2 + b-1 + b-2 + b-3 landed. Framework (1.1..1.6) +
  spike (2.1..2.3) + review-fix all landed.
  **Active task = Phase 6.16.b-4** (ADR-0035 + D-071 Part 3 +
  bootstrap loader topo-sort).
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md` (1593 lines).
- **Gate**: Mac 33/33 + OrbStack Ubuntu x86_64 32/32 green at
  ef4f683.
- **Provisional markers**: 16 markers / 8 entries in
  `feature_deps.yaml`. Hook (`scripts/check_provisional_sync.sh`)
  live + wired in `.claude/settings.json`. Audit checks
  E2.1..E2.4 in `audit_scaffolding`.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — Phase 6.16.b-4 (ADR-0035 + D-071 Part 3)

ADR-0035 issuance (require spec + multi-file dependency topo-sort
+ circular detection + `:as`/`:refer`/`:reload` semantics +
bootstrap loader topo-sort extension + D-058 per-file
SourceContext absorption + `(ns ...)` macro). Devil's-advocate
fork mandatory (depth ≥ 3). Closes D-063 + D-071 (Part 1 already
landed at 6.16.b-3; Part 3 `^:private` enforcement on
`-*-eager` leaves lands here).

Concurrent discharge: the 11-marker / 3-yaml-entry ns-machinery
cluster (`runtime/eval/in_ns_auto_refer` + `runtime/bootstrap/
refer_table` + `runtime/eval/bare_in_ns_decl`) — once `(ns ...)`
macro ships these entries flip provisional → landed and the 11
markers are removed in the same commit (the hook enforces sync).

v5 follow-up amendments accumulating (fold into ADR-0033 amendment
or next-cycle commit body):
- §5.2 DIVERGENCE D1 wording (contains? on vector, 6.16.a-2)
- §5.2 every?/some explicit Layer 2 designation (6.16.a-3.1)
- §5.2 + §7 transducer arity cw v1 deviation + D-070 trigger spec
- ADR-0033 D6a amendment (partial 着地、 D-070 後 back-fill)
- 6.16.b-1..b-3 evalInNs + bootstrap.zig + core.clj provisional
  (= ADR-0035 内包 discharge per spike 2.1)

## Open questions / blockers

None testable from inside the loop. Step 0.5 debt sweep walks
debt.md including D-062..D-076 (16 active rows). D-062 cluster
recall trigger anchored to placement.yaml.

## Guardrail refresh history (condensed)

Waves 1-14 (2026-05-23..25): spirit + Bad Smell + F-NNN +
ADR-0029..0034 + v5 plan + ROADMAP §9.8 + debt D-062..D-073.
**Wave 15 (2026-05-26)**: provisional-marker mechanisation
(rule + yaml SSOT + sync hook + Step 0.6 + audit E2 +
bootstrap_essence + 16-marker retrofit + review-fix).

## Stopped — user requested

User instruction (2026-05-26): "配線監査修正まで済んだら、止めて
おいてOK". Wave-15 work all landed. Resume at Phase 6.16.b-4
per Resume contract above.
