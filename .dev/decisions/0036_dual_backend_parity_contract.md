# 0036 — Dual-backend parity contract (Phase 7 entry)

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-26)
- **Date**: 2026-05-26
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: phase-7-entry, dual-backend, VM, tree-walk, parity, F-002, framework-completion

## Context

ADR-0005 declares dual-backend differential testing as the cw v1
oracle for evaluator correctness: TreeWalk and VM must agree on
every source. ADR-0021 + ADR-0022 wire the differential test layer
(`src/lang/diff_test.zig`). F-002 makes "the finished form wins"
project law: dropping the dual-backend promise after the fact is
the Smallest-diff bias smell elevated to ADR scale.

Reality at HEAD `0cd92fa` (Phase 7.1 dispatch ABI landing):

- `vm/compiler.zig:94-130` switches exhaustively over the 24-variant
  Node union — Zig surfaces a compile error if a new variant is
  added without a corresponding arm. The *arm-presence* layer is
  already enforced by the compiler.
- The *arm-body* layer is **not** enforced. 5 sites at HEAD ship
  with arms that either raise `error.NotImplemented` (4 sites:
  `deftype_node` / `ctor_call_node` / `field_access_node` triple
  + `compileRequire` libspec branch) or silently drop a
  significant field (1 site: `compileNs` discards
  `n.refer_clojure`). The differential test layer covers only
  9 of 24 Node variants, so the gaps cannot trip a CI failure.
- cw v0 final state (v0.5.0) carried the same drift class — VM
  arms shipped as "TODO Phase 7-10" and the catch-up consumed
  weeks of late-cycle time. cw v1's discipline machinery
  (PreToolUse hooks + Devil's-advocate fork mandate) was supposed
  to prevent the same outcome, but no rule explicitly covered
  "new analyzer Node → both backends in same commit," so the
  drift recurred at Phase 6.16.b-4 sub-cycles c.4 + c.5 + c.7
  (RequireNode libspec + NsNode filter) and again at Phase 5.12.a
  (deftype-family triple stub).

D-073 at `.dev/debt.md:98` recorded one symptom of this drift
(`has_rest` VM gap) without naming the cluster.

Source survey: `private/notes/phase7-T1-survey.md` (~440 lines,
HEAD `0cd92fa`).

## Decision

### D1 — Parity contract

Every commit that adds a variant to the `Node` union in
`src/eval/node.zig` MUST also land, in the same commit:

1. The TreeWalk eval arm in `src/eval/backend/tree_walk.zig`.
2. The VM compile arm in `src/eval/backend/vm/compiler.zig`.
3. The VM dispatch arm in `src/eval/backend/vm.zig` (when a new
   opcode is introduced).
4. At least one differential test case in `src/lang/diff_test.zig`
   exercising the new variant.

The compiler-enforced exhaustive switch (`vm/compiler.zig`'s
switch over `Node` has no `else =>` arm) ensures **arm presence**.
This ADR adds the contract for **arm body discipline** + diff
coverage.

### D2 — Allow-list marker `// VM-DEFER:`

When a VM compile arm cannot land its real implementation in the
introducing cycle (typically because the bytecode shape depends on
a not-yet-landed design choice in a future Phase row), the arm may
ship as a transient stub (`return error.NotImplemented;`) or as a
documented silent-field-drop (`_ = n.some_field;`) provided the
line directly above carries:

```zig
// VM-DEFER: <one-line why> [refs: D-NNN, feature_deps.yaml#<key>]
```

The marker mirrors the `// PROVISIONAL:` shape in
`.claude/rules/provisional_marker.md`:

- Single line. Multi-line rationale belongs in the `feature_deps.yaml`
  entry body or the `.dev/debt.md` row.
- `[refs:` block mandatory; at least one `D-NNN` AND one
  `feature_deps.yaml#<key>` reference.
- Placed directly above the affected statement; no blank line
  between marker and code.
- Removed (not commented-out) when the deferred implementation
  lands.

VM-DEFER is a sibling class to PROVISIONAL: same shape, different
concern. PROVISIONAL flags intermediate semantics that ride a
chicken-and-egg layer; VM-DEFER flags backend-asymmetry that rides
a Phase-N row's design choice.

### D3 — Discovery + enforcement

- Rule: `.claude/rules/dual_backend_parity.md` codifies the
  contract + cross-references this ADR + the hook script.
- Hook: `scripts/check_dual_backend_parity.sh` (PreToolUse on
  `git push`, registered in `.claude/settings.json`) blocks
  pushes whose unpushed commit range contains a
  `return error.NotImplemented` in `src/eval/backend/vm/*.zig`
  or `src/eval/backend/tree_walk.zig` without an adjacent
  VM-DEFER marker, OR a malformed VM-DEFER marker that lacks the
  `[refs: D-NNN, feature_deps.yaml#<key>]` block.

### D4 — Retrofit in the same cycle

Per `.claude/rules/framework_completion.md`, the introducing
cycle must run the discovery criterion against current HEAD and
retrofit each enumerated site. Sites at HEAD `0cd92fa`:

| # | Site (`vm/compiler.zig`)             | Body status                                            | T1 disposition           |
|---|--------------------------------------|--------------------------------------------------------|--------------------------|
| 1 | `deftype_node` arm (split from L115) | `return error.NotImplemented;` (triple-arm bundle)     | Split + VM-DEFER (D-073) |
| 2 | `ctor_call_node` arm (split)         | same                                                   | Split + VM-DEFER (D-073) |
| 3 | `field_access_node` arm (split)      | same                                                   | Split + VM-DEFER (D-073) |
| 4 | `compileRequire` libspec branch L393 | `if (n.alias != null or n.refers.len > 0) return ...;` | VM-DEFER (D-073)         |
| 5 | `compileNs` filter L380              | `_ = n.refer_clojure;` (silent field drop)             | VM-DEFER (D-073)         |

All 5 sites mark with VM-DEFER referencing D-073 + a
`feature_deps.yaml#runtime/vm/<key>` entry. D-073 is amended in
place from "`has_rest` VM gap" (single-site) to "VM backend
parity cluster" (5 sites + the original `has_rest` concern).

Diff coverage gap: 15 of 24 Node variants are not exercised by
any `src/lang/diff_test.zig` case at HEAD. T1 lands 11 new diff
cases covering all non-deferred variants (`def_node`, `do_node`,
`quote_node`, `try_node`, `throw_node`, `in_ns_node`,
`require_node` bare form, `ns_node`, `vector_literal_node`,
`map_literal_node`, `set_literal_node`). The 5 VM-DEFER sites
do not require diff cases until their markers are discharged.

### D5 — Scope of T1 vs follow-up

T1 (this ADR's introducing cycle) lands the contract + 5 VM-DEFER
markers + 11 diff cases + rule + hook. T1 does **not** land any
real VM implementation for the 5 deferred sites. The first
real-feature exercise of this contract is the `require` libspec
impl (Alt 2-refined Devil's-advocate selection): a dedicated
follow-up cycle introduces `op_require_with_libspec` (or
equivalent encoding chosen via its own Devil's-advocate fork),
discharges the `runtime/vm/require_libspec` VM-DEFER, and adds
2 diff cases (bare + libspec).

This split keeps T1 a pure discipline landing (smell-audit depth
2). Bundling the require-libspec opcode design would conflate
"land the contract" with "exercise the contract on a non-trivial
new opcode" and would push smell-audit to depth 3.

## Alternatives considered

The Devil's-advocate fork (fresh context, briefed against
F-NNN envelope from `.dev/project_facts.md`) produced 3
alternatives. Embedded verbatim:

### Alt 1 — Smallest-diff: retrofit-only, defer rule + hook + ADR

**Shape**: Land only the 5-site retrofit (libspec impl + 4 VM-DEFER markers) + 11 diff cases. Defer ADR-0036 / rule / hook to "when row 7.6 adds MethodCallNode and forces the question."

**Better than current draft**: ~450 LOC smaller, no hook-design risk surface (the hook may misfire on edge commits — e.g. cherry-pick chains, octopus merges; deferring lets a real second incident inform the matcher). Avoids Framework-incomplete risk on the *hook itself* (the hook is a new discipline whose own retrofit could be skipped in haste).

**Breaks**: This is the Framework-incomplete smell (`principle.md`) verbatim. `framework_completion.md` §C explicitly demands rule + retrofit ride the same cycle. Without the hook, the next analyzer-Node-adding cycle (row 7.2 multimethod or row 7.6 MethodCallNode) re-enacts the exact drift T1 exists to prevent — the cw v0 catch-up trap (survey §8.6). **F-002 violation**: chooses smallest-diff *because it is smallest*, not because it lands finished-form. **Rejected.**

### Alt 2 — Finished-form-clean (recommended, refined from proposal)

**Shape**: Largely matches the proposal, with three refinements:

1. **Defer `require` libspec impl to a follow-up cycle** alongside the rule + hook + ADR landing. Tag the existing libspec arm with `// VM-DEFER: require libspec pending op_require_with_libspec design [refs: D-073, feature_deps.yaml#runtime/vm/require_libspec]`. Rationale: bundling a new opcode design (operand encoding, heap Vector packaging, dispatch arm, 2 diff cases) into the T1 discipline-landing cycle conflates "land the contract" with "exercise the contract on a real payload." The proposal's reasoning ("require libspec is the only active user-visible gap, T2 needs it") is real but **T2's ADR-0035 D2 second amendment is itself a follow-up cycle**, not T2 proper — Symbol Value (T2) does not depend on require libspec VM parity, only T2's *optional* `require`-as-runtime-fn migration does. The libspec impl can land as the first exercise of ADR-0036 (cycle that proves the contract works on a real new feature). This keeps T1 as a pure discipline landing: rule + hook + markers + diff cases for **fully-working arms only**.

2. **Single-commit cluster** (matches proposal): rule + hook + ADR + 5 marker retrofits + 11 diff cases in one Step 6 commit. `framework_completion.md` §C demands same-cycle; splitting into T1.a/T1.b violates the rule the cycle introduces. Smell-audit depth 2 is normal cw v1 practice (commits 8d4841c / a762ca9 set the precedent for multi-file structural cluster landings).

3. **Hook stays at PreToolUse:Bash on `git push`** (matches proposal), not PreToolUse:Edit on node.zig. Rationale: the discovery criterion needs the *commit's full tree*, not a mid-edit view — Edit-time enforcement would block partial in-progress edits where the developer is mid-way through landing both arms. The push-time hook matches `check_provisional_sync.sh`'s shape and uses the proven `hook_iter_unpushed` walker.

**Marker form**: `// VM-DEFER:` mirroring `// PROVISIONAL:` is correct — same `[refs: D-NNN, feature_deps.yaml#<key>]` block, same single-line discipline. Differing surface name (`VM-DEFER` vs `PROVISIONAL`) preserves grep-distinguishability between "feature is intermediate semantics" (PROVISIONAL) vs "VM backend defers to tree_walk" (VM-DEFER) — these are different abstractions with different close-out predicates.

**Diff coverage**: per-Node-variant requirement (proposal's choice) is correct. Per-commit-touching-backend would be looser and miss the case where a new Node variant lands without any new test (the precise gap that produced the 15 untested variants at HEAD).

**Better than proposal**: cleaner separation between "contract lands" and "contract gets exercised on a non-trivial new opcode." The require libspec impl deserves its own Devil's-advocate (operand encoding choice between recommendation §3.1 options A/B/C is non-trivial — option A's `Vector<String>` is the survey author's call but not subagent-verified). Bundling it forces a depth-3 decision into the depth-2 contract-landing.

**Breaks**: leaves one user-visible gap (`(require '[clojure.set :as s])` still raises `NotImplemented` on `-Dbackend=vm`) for one additional cycle. Mitigated by VM-DEFER marker making the gap explicit + grep-discoverable + hook-tracked, plus the existing reality that VM backend is opt-in (`-Dbackend=vm`), so default users (tree_walk) see no change.

### Alt 3 — Wildcard: kill VM backend

**F-NNN violation finding (leading entry)**: **Alt 3 violates F-002.** ADR-0005 declares dual backend as the finished form; F-002 declares finished-form wins, and the Smallest-diff bias smell explicitly names "let me drop the hard-to-maintain thing post-hoc" as forbidden. Killing VM backend because parity discipline is expensive is the textbook Smallest-diff bias smell elevated to ADR scale. The main loop must not propose this alternative as a recommendation; it is recorded here per the Devil's-advocate brief's instruction to lead with F-NNN findings.

**Shape (for the record)**: Delete `src/eval/backend/vm/`, delete `src/lang/diff_test.zig`, supersede ADR-0005 + ADR-0021 Layer 3 + ADR-0022, declare tree_walk as the only path until Phase 17 JIT lands.

**Better than current draft**: eliminates the VM gap class permanently; saves ~3000 LOC of VM machinery; removes the entire dual-backend discipline cost from every future Node addition.

**Breaks**: F-002 violation (above). Also: ADR-0005's "Phase 17 JIT joins the same comparison" extension premise dies; JIT activation later would need to re-build a comparison oracle from scratch. cw v0 retrospective evidence (survey §8.6) is that the VM backend itself is not the problem — *unenforced* parity discipline was. Alt 3 would solve a discipline gap by killing the discipline's target, which is structural surrender.

**F-NNN compliance**: would require a user-direction F-NNN amendment to override F-002 + an explicit user direction to deprecate ADR-0005. Outside the loop's authority per `project_facts.md`.

### Devil's-advocate recommendation

**Alt 2 (refined)**: single-commit cluster landing rule + hook + ADR-0036 + 4 VM-DEFER markers (deftype / ctor_call / field_access / ns refer-clojure filter) + 11 diff cases + D-073 amendment in place. Defer **require libspec impl** to a dedicated follow-up cycle that becomes ADR-0036's first real-feature exercise (lands `op_require_with_libspec` + 2 diff cases + discharges that one VM-DEFER marker).

F-NNN reasoning: F-002 forbids Alt 1 (smallest-diff bias) and Alt 3 (post-hoc surrender of dual backend finished form). F-009 keeps rule + hook outside `src/`. F-004 unaffected. F-007 unaffected. The refinement carves out require-libspec impl from T1 because the libspec opcode design is itself depth-3 territory (operand encoding choice) and deserves its own Devil's-advocate, not piggyback-acceptance under T1's contract-landing smell-audit. Net: T1 = pure discipline + 4 markers + 11 diff cases; require-libspec = one follow-up cycle that proves the contract works on its first new-feature exercise.

## Selection rationale

Selected: Alt 2 refined.

- F-002: dual backend stays as the finished form; T1 mechanises
  the protection. Alt 1 violates by deferring the discipline;
  Alt 3 violates by abandoning the finished form.
- F-009: rule + hook live outside `src/`; VM compile arms remain
  in `src/eval/backend/vm/`. No zone leak.
- F-004: T1 introduces no new heap value shape (the require
  libspec opcode design that would touch encoding is carved out
  to the follow-up cycle).
- F-007: chapter cadence dormant — no `docs/ja/learn_clojurewasm/`
  touch.

Devil's-advocate's carve-out of `require` libspec impl from T1
is adopted: T1 = 5 VM-DEFER markers (not 4 markers + 1 impl).
This keeps T1's smell-audit at depth 2 and surfaces the opcode
encoding choice as its own depth-3 decision in the follow-up
cycle (where Devil's-advocate weighs Vector<String> packaging
vs constant-pool sequencing vs op_invoke_builtin sub-chunk per
survey §3.1).

## Consequences

### Positive

- Drift class eliminated mechanically. Future Node additions
  trip the hook unless both backends + diff coverage land in the
  same commit (modulo explicit VM-DEFER + tracked debt row).
- The 5 existing gaps become grep-discoverable + tracked. The
  `_ = n.refer_clojure;` silent-drop pattern (the only true
  silent-failure shape at HEAD) is now named, not buried.
- D-073 carries proper cluster scope; future Step 0.5 sweeps see
  the full 5-site list rather than the single `has_rest` symptom.
- The 11 new diff cases close 11 of 15 untested-variant gaps in
  `src/lang/diff_test.zig`, making the differential oracle a real
  oracle for the bulk of the Node union.

### Negative

- Cycle cost ~1.5x vs a retrofit-only cycle (Alt 1). ~650 LOC
  total change across ADR + rule + hook + markers + diff cases +
  D-073 amendment + yaml entries.
- The hook adds one more PreToolUse:Bash gate to `git push`
  latency. Self-test under `test/scripts/` keeps execution
  bounded.
- `(require '[clojure.set :as s])` continues to raise
  `error.NotImplemented` on `-Dbackend=vm` until the follow-up
  cycle. Mitigated: VM backend is opt-in; default users see no
  change.

### Neutral / follow-ups

- **Follow-up cycle A** (post-T1, when scheduled): `require`
  libspec impl as ADR-0036's first real-feature exercise.
  Introduces `op_require_with_libspec` (encoding TBD via its own
  Devil's-advocate) + 2 diff cases; discharges
  `runtime/vm/require_libspec` VM-DEFER.
- **Phase 7.6**: MethodCallNode landing discharges the 3
  deftype-family VM-DEFER markers (decides the dispatch-family
  bytecode shape for deftype + ctor + field_access + method).
- **NsNode filter extension** (analyzer side, Phase 6.16.b-4
  follow-up or Phase 7+): when `:exclude` / `:only` directives
  land, the VM `compileNs` arm picks up the filter encoding and
  discharges the `runtime/vm/ns_filter` VM-DEFER.

## Affected files

- `.dev/decisions/0036_dual_backend_parity_contract.md` — this ADR (new).
- `.claude/rules/dual_backend_parity.md` — discipline rule (new).
- `.dev/principle.md` — adds "Dual-backend drift" Bad Smell entry.
- `.dev/debt.md` — amends D-073 in place from single-site
  `has_rest` to 5-site cluster + `has_rest`.
- `feature_deps.yaml` — adds 3 entries:
  `runtime/vm/dispatch_family`, `runtime/vm/ns_filter`,
  `runtime/vm/require_libspec`.
- `src/eval/backend/vm/compiler.zig` — splits the deftype-family
  triple arm into 3 separate arms; adds 5 VM-DEFER markers.
- `src/lang/diff_test.zig` — adds 11 new diff cases.
- `scripts/check_dual_backend_parity.sh` — PreToolUse hook (new).
- `scripts/hook_lib.sh` — used as-is, no edits required.
- `test/scripts/check_dual_backend_parity_test.sh` — hook
  self-test (new).
- `.claude/settings.json` — registers the new hook in
  PreToolUse:Bash chain.

## References

- ADR-0005 — dual-backend differential testing as oracle (this
  ADR's foundational precedent).
- ADR-0021 — test taxonomy (Layer 3 differential).
- ADR-0022 — differential wiring.
- ADR-0008 amendment 1 — Phase 7.1 dispatch ABI (the row whose
  landing surfaced the deftype-family triple stub as Phase 7
  territory).
- `.claude/rules/framework_completion.md` — discovery + sweep +
  retrofit-in-same-cycle discipline this ADR operationalises.
- `.claude/rules/provisional_marker.md` — the PROVISIONAL marker
  whose shape VM-DEFER mirrors.
- `.dev/project_facts.md` F-002 (finished-form wins), F-004
  (NaN-box layout), F-007 (chapter cadence dormant), F-009 (impl
  neutrality).
- `private/notes/phase7-T1-survey.md` — Step 0 survey (~440
  lines) carrying the gap inventory + sweep result.
- `.dev/phase7_entry_prereq_triad.md` §T1 — operational driver
  for this ADR's introducing cycle.

## Revision history

- 2026-05-26: Status: Proposed → Accepted (initial landing).
  Devil's-advocate fork (depth-2 mandatory) executed against
  F-NNN envelope; Alt 2 refined selected. T1 cycle lands this
  ADR + rule + hook + 5 VM-DEFER markers + 11 diff cases as a
  single-commit cluster per Devil's-advocate recommendation,
  split into a doc-first commit (this file + rule + debt + yaml
  + principle) followed by a source/hook commit per CLAUDE.md
  Step 6 depth-2 discipline.
