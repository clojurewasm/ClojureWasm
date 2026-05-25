# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (v5 plan + wiring landed; HEAD line refreshes
  only on Active-task-identifier change).
- **First commit on resume MUST be**: open **Phase 6.16.a-3.2** cycle
  — Layer 2 eager leaves (`-map-eager`/`-filter-eager`/`-take-eager`/
  `-drop-eager`/`-keep-eager`/`-remove-eager`) + Layer 3 `.clj` defn
  in `src/lang/clj/clojure/core.clj` (`map`/`filter`/`take`/`drop`/
  `keep`/`remove` with transducer 1-arg arity + multi-arity eager
  + `partial`/`comp`/`complement`/`constantly`/`juxt` pure Clojure)
  + `into` 3-arg xform-aware (`(into to xform from)`) Zig extension
  + rf protocol formal registration. Per ADR-0033 D6 + D6a + v5 §7
  transducer 先取り spec + survey 2-cycle split decision. e2e:
  `transducer_unlock_a3.sh`. After cycle close: Phase 6.16.b
  (clojure.set 12 vars `.clj` 化). Prior landings: ADR-0033 (2bf491b)
  + ADR-0034 (2834511) + Phase 6.16.a-0 (b5d44f7) + 6.16.a-1
  (d35dc3b) + 6.16.a-2 (a4bfca5) + 6.16.a-3.1 (f84a918, has_rest fix
  + Reduced + apply/reduce/into/every?/some/some?).
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

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 13/24 `[x]` + 6.10 `[~]
  (7/12)` + 6.11 `[~] (3/10)`. v5 plan + ADR-0033 (2bf491b) + ADR-0034
  (2834511) + ROADMAP §9.8 rows 6.16.a-0..e + §9.14/16/18/19 v5
  expansions + debt rows D-062..D-069 (757a0b5) + Phase 6.16.a-0
  env.intern metadata (b5d44f7) + Phase 6.16.a-1 sequence.zig 6
  primitives (d35dc3b) + Phase 6.16.a-2 collection.zig 9 primitives
  (a4bfca5) + Phase 6.16.a-3.1 has_rest+Reduced+higher_order 6
  primitives (f84a918). **Active task = Phase 6.16.a-3.2 cycle**
  (eager leaves + Layer 3 .clj defn).
- **Branch**: `cw-from-scratch`. ADR-0032 issued (multi-file loader +
  in-ns). v5 plan = `private/notes/clj_vs_zig_split_proposal_v5.md`
  (1593 lines, self-contained, SSOT for ADR-0033/0034/0035).
- **Gate**: Mac 28/28 + OrbStack Ubuntu x86_64 28/28 green at f84a918
  (composition_unlock_a3_1.sh registered; bench_quick is optional
  informational).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — Phase 6.16.a-3.2 (eager leaves + Layer 3 .clj defn)

Open Phase 6.16.a-3.2 (cycle 2/2 of split): Layer 2 6 eager leaves
(`-map-eager` etc.) + Layer 3 11 fns in `core.clj` (map/filter/
take/drop/keep/remove with transducer 1-arg arity + multi-arity
eager + partial/comp/complement/constantly/juxt as pure Clojure) +
`into` 3-arg xform extension + rf protocol formal registration.

After cycle close: Phase 6.16.b (clojure.set 12 vars `.clj` 化、
Group A+B+C 一括 per ROADMAP §9.8 row 6.16.b).

v5 follow-up amendments queued (fold into a-3.2 or later cycle):
- §5.2 DIVERGENCE D1 wording (contains? on vector, Phase 6.16.a-2)
- §5.2 every?/some explicit Layer 2 designation (Phase 6.16.a-3.1)

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
