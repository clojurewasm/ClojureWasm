# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (v5 plan + wiring landed; HEAD line refreshes
  only on Active-task-identifier change).
- **First commit on resume MUST be**: open **Phase 6.16.b** cycle —
  `clojure.set` 12 vars `.clj` 化 (Group A+B+C 一括) per ADR-0033
  D7 + ROADMAP §9.8 row 6.16.b + v5 §8.2 + §9. The 12 vars: union /
  intersection / difference / subset? / superset? / rename-keys /
  map-invert / select / project / index / rename / join. Pattern A
  (pure Clojure composition over reduce/conj/disj/contains?/count/
  every?/etc — all now landed). Group C (5 relational ops) requires
  set-literal reader + map-literal analyzer (D-061 + D-059) — fold
  these gap closes into 6.16.b cycle. Also: open **ADR-0035** (require
  spec, D-063) at the same cycle since multi-file dependency order
  becomes load-bearing once set.clj defns reference partial/comp/
  juxt etc from core.clj. Step 0 survey via general-purpose subagent
  first (output `private/notes/phase6-6.16.b-survey.md`). e2e:
  `clojure_set_full.sh`. After 6.16.b: Phase 6.16.c (clojure.walk).
  Prior landings: ADR-0033 (2bf491b) + ADR-0034 (2834511) + 6.16.a-0
  (b5d44f7) + 6.16.a-1 (d35dc3b) + 6.16.a-2 (a4bfca5) + 6.16.a-3.1
  (f84a918) + 6.16.a-3.2 (1d20ce3, includes D-060 close + D-070/
  D-071/D-072/D-073 open).
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

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 14/24 `[x]` + 6.10 `[~]
  (7/12)` + 6.11 `[~] (3/10)`. v5 plan + ADR-0033 (2bf491b) + ADR-0034
  (2834511) + Phase 6.16.a-0 (b5d44f7) + a-1 (d35dc3b) + a-2 (a4bfca5)
  + a-3.1 (f84a918) + a-3.2 (1d20ce3, +D-060 close + D-070/D-071/D-072/
  D-073 open). **Active task = Phase 6.16.b cycle** (clojure.set 12
  vars `.clj` 化 + ADR-0035 require spec).
- **Branch**: `cw-from-scratch`. ADR-0032 issued (multi-file loader +
  in-ns). v5 plan = `private/notes/clj_vs_zig_split_proposal_v5.md`
  (1593 lines, self-contained, SSOT for ADR-0033/0034/0035).
- **Gate**: Mac 30/30 + OrbStack Ubuntu x86_64 29/29 green at 1d20ce3
  (composition_unlock_a3_1.sh + transducer_unlock_a3.sh registered).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — Phase 6.16.b (clojure.set 12 vars .clj 化)

Open Phase 6.16.b: 12 vars (union/intersection/difference/subset?/
superset?/rename-keys/map-invert/select/project/index/rename/join)
as pure Pattern A defns in `src/lang/clj/clojure/set.clj`. Group C
relational ops (5 vars) require D-061 (set-literal reader) +
D-059 (map-literal analyzer) gap closes — fold these into 6.16.b
cycle. Concurrently: ADR-0035 (require spec, D-063) issuance —
multi-file dependency order becomes load-bearing.

After 6.16.b: Phase 6.16.c (clojure.walk 10 vars .clj 化).

v5 follow-up amendments accumulating (fold into ADR-0033 amendment
or next-cycle commit body):
- §5.2 DIVERGENCE D1 wording (contains? on vector, 6.16.a-2)
- §5.2 every?/some explicit Layer 2 designation (6.16.a-3.1)
- §5.2 + §7 transducer arity cw v1 deviation + D-070 trigger spec (6.16.a-3.2)
- ADR-0033 D6a amendment (partial 着地、 D-070 後 back-fill plan)

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
