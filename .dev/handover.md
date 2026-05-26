# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Resume contract

- **HEAD**: see `git log` (HEAD refreshes only on Active-task-
  identifier change).
- **First commit on resume MUST be**: open **Phase 7.0** — boundary
  review chain (audit_scaffolding + bench sweep + Phase tracker
  refresh). Then proceed to **Phase 7.1** (ADR-0008 amendment 1 —
  full protocol dispatch + CallSite cache; rewire Phase 5's
  `TypeDescriptor.lookupMethod` direct calls through
  `dispatch(rt, cs, receiver, protocol, method, args)`). Survey via
  general-purpose subagent first (output `private/notes/phase7-7.1-survey.md`).
- **Forbidden this session**: (a) `__zig-` namespace prefix path.
  (b) `clojure.X.impl/` sub-ns path. (c) `cljw build --source/
  --debug/--aot` flag path. (d) mixing human + EDN in single
  stderr stream. (e) ABI-level bytecode format commitment.
  (f) introducing new PROVISIONAL markers without same-commit
  yaml + debt.md sync (the hook will physically block — see
  `.claude/rules/provisional_marker.md`).

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009)
→ `.dev/principle.md` (Bad Smell + Devil's-advocate mandate) →
**`private/notes/clj_vs_zig_split_proposal_v5.md` (placement /
build / error 確定計画 SSOT)** → `.claude/rules/provisional_marker.md`
(marker lifecycle + SSOT triad) → `feature_deps.yaml` (5 provisional
entries / 5 marker sites) → `.dev/structure_plan.md` →
`.dev/ROADMAP.md` §9.9 (Phase 7 task table opened 2026-05-26).

## Current state

- **Phase**: **Phase 6 DONE** (closed 2026-05-26) — §9.8 all rows
  resolved (6.0..6.16.* [x]; 6.12 deferred to D-080).
  **Phase 7 IN-PROGRESS** — §9.9 task table opened with 16 rows.
  **Active task = Phase 7.0** (boundary review chain) → **7.1**
  (protocol dispatch + CallSite cache).
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md` (1593 lines).
- **Gate**: Mac 41/41 + OrbStack Ubuntu x86_64 40/40 green at
  2aca7b4 (current HEAD = ROADMAP bookkeeping commits past that).
- **Provisional markers**: 5 markers / 5 entries remaining in
  `feature_deps.yaml` (D-070 join, D-074 map-invert, D-075
  project + rename, D-076 rename-keys, D-077 catch_class_table).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — Phase 7.0/7.1 (protocol dispatch + CallSite cache)

ADR-0008 amendment 1 implements the full protocol dispatch path
that Phase 5 left at `TypeDescriptor.lookupMethod` direct calls.
Per-call-site monomorphic cache + `dispatch(rt, cs, receiver,
protocol, method, args)` ABI. CallSite shape landed at Phase 4
task 4.25 skeleton; Phase 7.1 wires real dispatch through it.
`runtime/protocol/stub.zig` → real impl. Devil's-advocate fork
mandatory at depth ≥ 2 if ADR amendment is required (likely).

Phase 7 §9.9 carries 15 task rows total (7.0..7.15) covering
protocol/defprotocol/multimethod/defrecord/reify + the deferred
items from Phase 6 (D-069 hybrid polymorphism, D-070 multi-arity
fn*, D-072 apply-on-lazy-seq, D-073 VM parity, D-077 catch
table, D-078 string RED set, D-080 clojure.zip).

## Open questions / blockers

None testable from inside the loop. Step 0.5 sweep walks
remaining open debt rows; Phase 7 work resolves D-069..D-080
cluster.

## Guardrail refresh history (condensed)

Waves 1-16 (2026-05-23..26): spirit + Bad Smell + F-NNN +
ADR-0029..0034 + v5 plan + ROADMAP §9.8 + debt D-062..D-073 +
provisional-marker mechanisation + hook_lib.sh +
watch_findings.md + framework_completion + audit E2 expansion.
Phase 6 close (2026-05-26): ADR-0035 + 6.16.b-4 (10 commits) +
6.16.c (6 commits) + 6.16.d (1 commit) + 6.16.e.{1,2,3}
(3 commits) + Phase 6 exit smoke + phase_at_least_6 flip +
ROADMAP §9.8 bookkeeping. 11 PROVISIONAL marker discharge at
sub-cycle d of 6.16.b-4. New rt primitives: keyword / name /
println / str / subs.
