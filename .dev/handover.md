# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (Phase 6.9 cycle 1 just landed; HEAD line
  refreshes only on Active-task-identifier change per the
  ≤ 2 / session cap).
- **First commit on resume MUST be**: §9.8 row 6.10 =
  `lang/clj/clojure/set.clj` (Tier A, ~12 vars). Survey at
  `private/notes/phase6-6.10-survey.md` first (Step 0). The
  bootstrap loader + `(in-ns)` are already wired (ADR-0032) and
  vector-literal evaluation + pr-str + multi-clj-load
  infrastructure is all in place after 6.9 cycle 4. Phase 6.9
  row already flipped to `[x]` in §9.8.
- **Forbidden this session**: (a) re-opening `core.zig` /
  `math.zig` primitive cluster (6.16 still closed). (b) handover
  HEAD-pointer churn — refresh only when Active-task-identifier
  changes. (c) acting on the **original** (pre-2026-05-25-amendment)
  D-054 plan that referenced a non-existent JVM upstream
  `regex.clj` — read the amended D-054 + deep-dive note first.
  (d) Implementing Unicode case-folding inline in cycle 2 — D-057
  tracks it for Phase 11 conformance; cycle 2 stays ASCII-fold.

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009)
→ `.dev/principle.md` (Bad Smell + Devil's-advocate mandate)
→ `.dev/structure_plan.md` → `.dev/ROADMAP.md` §9.8.

## Current state

- **Phase**: **Phase 6 IN-PROGRESS** — §9.8 10/16 `[x]`
  (6.1, 6.5.b, 6.10-6.15 remain). 6.9 closed end-to-end across
  4 cycles: cycle 1 = loader + `(in-ns)` + 3 vars; cycle 2 =
  trim + predicate families (7 vars); cycle 3 = indexing +
  replace string-only + escape (fn cmap) + reverse (6 vars);
  cycle 4 = `capitalize` + `split` + `split-lines` + `join`
  + vector literal evaluation + vector pr-str. 22 vars total
  in `clojure.string` ns.
- **Branch**: `cw-from-scratch`. ADR-0032 issued (multi-file
  loader + in-ns). Symbol-Value-Form unsupported at runtime
  (Group A slot 1 reserved per F-004) → `(in-ns)` lands as
  analyzer special form, not primitive fn — analyzer flattens
  bare `(in-ns sym)` and quoted `(in-ns 'sym)` to InNsNode.
- **Gate**: Mac 22/22 + OrbStack Ubuntu x86_64 21/21 green.
  Four Layer-2 e2e: `phase6_clojure_string_cycle{1,2,3,4}`
  (9 + 16 + 13 + 14 cases).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.8 row 6.10 (clojure.set)

`lang/clj/clojure/set.clj` (Tier A, ~12 vars). Spawn a Step-0
survey subagent to map `clojure.set` against JVM upstream
(`~/Documents/OSS/clojure/src/clj/clojure/set.clj`) and cw v0
(`~/Documents/MyProducts/ClojureWasm/src/lang/builtins/...`).
`set?` predicate is already in `core.zig` (cycle 1 verified).
The 4 cycles of 6.9 worked off the survey at
`private/notes/phase6-6.9-survey.md` — the same template
applies. set-Value Tag is already day-1 reserved (Group A
slot 7 — `hash_set`). Cycles likely fan out as: cycle 1 =
foundation + 2-3 simplest (`union` / `intersection`).

## Open questions / blockers

None testable from inside the loop. Step 0.5 debt sweep walks
debt.md (D-005, D-014a/b, D-017, D-040, D-043, D-048..D-052,
D-054, D-056..D-059, **D-060 new** VM op_vector_literal —
TreeWalk path landed, VM raises NotImplemented).

## Guardrail refresh history (condensed)

Waves 1-12: spirit + Bad Smell + F-NNN + stop-list + ADR-0029
F-009 + ADR-0030 + 6.1 analyzer split + ADR-0031 Accepted
(Alt 2) + 6.16 cluster (48 fns) + silent-test-skip surgery +
clock API port (D-053). **Wave 13 (2026-05-25)**:
ADR-0032 multi-file bootstrap loader + `(in-ns)` analyzer
special form + Devil's-advocate fork (Alt 1 smallest-diff /
Alt 2 finished-form / Alt 3 wildcard); cycle 1 e2e green;
D-057 + D-058 minted.
