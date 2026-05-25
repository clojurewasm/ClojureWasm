# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (v5 plan + wiring landed; HEAD line refreshes
  only on Active-task-identifier change).
- **First commit on resume MUST be**: open **Phase 6.16.a-1** cycle —
  core glue fundamentals (count / seq / first / rest / cons / empty)
  per ADR-0033 D6 + ROADMAP §9.8 row 6.16.a-1 + v5 §5.2. Step 0 survey
  required (general-purpose subagent, output
  `private/notes/phase6-6.16.a-1-survey.md`), then TDD red/green/refactor
  for the 6 primitives with polymorphic Tag switch + Protocol-ready
  interface per v5 §6.1 hybrid polymorphism. Also include Tier 0
  metadata size measurement bench (ADR-0034 prerequisite per v5 §11.5
  + §24.5 U-1) within this cycle. e2e deliverable:
  `test/e2e/composition_unlock_a1.sh`. After this cycle lands:
  Phase 6.16.a-2 (collection ops conj/disj/contains?/get/nth/assoc/
  dissoc/keys/vals). ADR-0033 (b5d44f7 not yet — landed at 2bf491b
  earlier) and Phase 6.16.a-0 (b5d44f7) are both complete.
- **Forbidden this session**: (a) `__zig-` namespace prefix path (v5
  §3.1 rejected; `defn-` + `-name` + `^:private :zig-leaf` metadata is
  the confirmed scheme). (b) `clojure.X.impl/` sub-ns path (v5 §3 rejected
  for取り残しリスク + 分散コスト). (c) `cljw build --source` / `--debug`
  / `--aot` flag path (v5 §11.1 confirmed single mode, flag ゼロ). (d)
  mixing human + EDN in single stderr stream (v5 §13.1 confirmed
  stream-separated TTY=human / pipe=structured EDN). (e) ABI-level
  bytecode format commitment (v5 §12.4 confirmed self-contained binary,
  decoder-only永久互換性).

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` (Bad Smell + Devil's-advocate mandate) →
**`private/notes/clj_vs_zig_split_proposal_v5.md` (placement +
build + error 確定計画 SSOT)** →
`.dev/structure_plan.md` → `.dev/ROADMAP.md` §9.8.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 11/24 `[x]` + 6.10 `[~]
  (7/12)` + 6.11 `[~] (3/10)`. v5 plan + ADR-0033 (2bf491b、 Accepted)
  + ROADMAP §9.8 rows 6.16.a-0..e + §9.14/16/18/19 v5 expansions +
  debt rows D-062..D-069 (757a0b5) + Phase 6.16.a-0 env.intern metadata
  expansion (b5d44f7、 D-065 解消). **Active task = Phase 6.16.a-1
  cycle** (core glue fundamentals).
- **Branch**: `cw-from-scratch`. ADR-0032 issued (multi-file loader +
  in-ns). v5 plan = `private/notes/clj_vs_zig_split_proposal_v5.md`
  (1593 lines, self-contained, SSOT for ADR-0033/0034/0035).
- **Gate**: Mac 26/26 + OrbStack Ubuntu x86_64 24/24 green at b5d44f7
  (Phase 6.16.a-0 e2e `phase6_16_a_0_metadata.sh` registered).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — Phase 6.16.a-1 (core glue fundamentals)

Open Phase 6.16.a-1 cycle: count / seq / first / rest / cons / empty
as Layer 2 polymorphic Tag switch + Protocol-ready interface (v5 §6.1
hybrid polymorphism). Per ADR-0033 D6 + ROADMAP §9.8 row 6.16.a-1.
Order: count → seq → first → rest → cons → empty. Include Tier 0
metadata size measurement bench (ADR-0034 起票 prerequisite). e2e
deliverable: `test/e2e/composition_unlock_a1.sh`. Step 0 survey via
general-purpose subagent first; then TDD red/green/refactor.

After this cycle: Phase 6.16.a-2 (collection ops conj/disj/contains?/
get/nth/assoc/dissoc/keys/vals). ADR-0033 (2bf491b) + ROADMAP wiring
(757a0b5) + Phase 6.16.a-0 (b5d44f7) all landed.

## Open questions / blockers

None testable from inside the loop. Step 0.5 debt sweep walks
debt.md including new rows D-062..D-069 (v5 §21.1). D-062 cluster
recall trigger anchored to placement.yaml — initial scaffold landed
at `placement.yaml`, populated incrementally as cycles close.

## Guardrail refresh history (condensed)

Waves 1-12: spirit + Bad Smell + F-NNN + stop-list + ADR-0029 F-009
+ ADR-0030 + 6.1 analyzer split + ADR-0031 Accepted (Alt 2) + 6.16
cluster + silent-test-skip surgery + clock API port. **Wave 13
(2026-05-25)**: ADR-0032 multi-file bootstrap loader + `(in-ns)`
analyzer special form. **Wave 14 (2026-05-25)**: v5 placement/build/
error plan landed (`private/notes/clj_vs_zig_split_proposal_v5.md`)
+ ROADMAP §9.8 cycle rows 6.16.a-0..e + ROADMAP §9.14/16/18/19
deliverable extensions + debt.md D-062..D-069 + placement.yaml stub
+ ADR-0033/0034/0035 起票計画 (ADR-0033 immediate, 0034/0035 cycle-
terminus deferred).
