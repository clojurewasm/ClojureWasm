# 0051 — Interim-goal re-cut: milestone M (Phase 15 + cw-v0 JIT) then a quality-elevation loop, wasm FFI re-sequenced

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude, user-directed re-cut session)
**Tags**: roadmap-resequence, F-010, F-001, F-002, F-003, quality-loop, jit

## Context

User intervention (2026-05-29): re-cut the interim provisional goal.
Captured as project-law invariant **F-010** (`.dev/project_facts.md`,
verbatim quote). The direction is user-fixed; this ADR records the
**engineering expression** of that direction in ROADMAP §9 + §14,
within the F-003 structural-deferral discipline.

Three surveys grounded the re-cut (digested in
`private/notes/recut-goal-synthesis.md`):

- cw v1 current coverage — biggest gaps: interop *syntax*
  `.`/`new`/`set!`/`dosync` unimplemented; clojure.core daily-driver
  cluster missing (`get-in`/`assoc-in`/`concat`/`mapcat` D-126,
  `pr-str`/`prn` D-127); seqs eager not lazy; thin clj ns + spec/math
  untouched; diff layer (TreeWalk vs VM) unwired. **The runtime
  cannot yet run real Clojure code well.**
- cw v0 JIT — `src/engine/vm/jit.zig` 721 LOC, ARM64-only narrow
  integer-loop JIT, counter trigger (64), one-shot deopt, leaf C-ABI,
  zero GC interaction by avoidance; 10.3x on `arith_loop` only. cw v1
  prerequisite: a superinstruction/fusion pass (cw v1 opcodes are
  generic). Zig 0.16 `std.posix.mmap`/`mprotect` available.
- cw v0 coverage baseline — 1130 vars / 90.9% / 651-706 clojure.core,
  spec.alpha 100%. cw v0 dropped deftype/proxy/gen-class (Tier D);
  **cw v1 native deftype gives a higher ceiling = parity-PLUS target.**

## Decision

### D1: Post-Phase-14 execution order (direction, per F-010)

```
Phase 14 (v0.1.0)  →  Phase 15 (concurrency, 7 buckets)
                   →  JIT chain (superinstruction/fusion → go/no-go →
                      cw-v0-level narrow ARM64 JIT)      ── completes M
                   →  quality-elevation loop (repeatable, standing mode)
                   →  wasm FFI breadth (ClojureScript, zwasm v2 import,
                      broad JIT if chosen)               ── after the loop
```

This **re-sequences** the prior §9.2 milestone mapping (which placed
CLJS at Phase 16 / v0.2.0 before the JIT). The JIT (currently split
across §9.19 Phase 17 super_instruction + §9.22 Phase 20 narrow JIT)
is pulled into the M window, immediately after Phase 15. The wasm
phases (§9.18 Phase 16 CLJS, §9.19's wasm content, §9.22 zwasm import)
slide to **after** the quality loop. **F-001 (wasm FFI eventually
unavoidable) is NOT superseded** — it is re-scheduled; F-010
cross-references it.

### D2: ROADMAP expression = light re-label + debt-recorded foresight (NOT full renumber)

Per **F-003** (decision-deferral on structural plans), F-010 fixes the
**direction** but not the **granularity** (exact phase renumbering,
quality-loop sub-phase structure, the JIT-subtree extraction shape,
the coverage-floor-vs-superinstruction ordering). Granularity is an
*open structural plan* → reserved for each owning Phase entry. This
ADR therefore:

- Adds a **re-sequencing note** to ROADMAP §9 (after §9.16) recording
  the D1 order + that detailed renumber/expansion defers to each Phase
  entry owner.
- Records foresight as **debt rows**, not seized task tables:
  - **D-132** — quality-elevation loop phase structure (sub-phase
    count / numbering / ownership): open, decide at the M-exit entry.
  - **D-133** — JIT coverage-floor prerequisite: the daily-driver
    coverage floor (interop syntax; D-126/127 core cluster; true
    lazy-seq) must be green so the JIT lands on a runtime that runs
    real code; the *ordering* of this floor vs the superinstruction
    pass is the JIT-phase entry owner's call (recorded, deferred).
- The zwasm/CLJS relocation is a **header/pointer move** (direction
  fixed by F-010), NOT a renumber of the zwasm task body or its
  D-036..D-039 entry-debt internals (that stays the owning entry's
  call).

### D3: The quality-elevation loop (standing post-M work mode)

Repeatable cycle, each pass refactor-gated (F-002 applied to the
bug-fix stream): (1) coverage → cw-v0 parity-PLUS; (2) clojuredocs
posted-example differential vs JVM Clojure
(`clojuredocs-export-edn`, ~1528 vars with `:examples`); (3)
real-world library loading (`clojure-corpus`, 200+ libs); (4)
differential fuzzing vs JVM + generative properties; (5) `docs/works/`
code-主体 walkthrough ledger. **Refactor gate**: a fix that would
require a workaround triggers a depth-2+ surgery instead; periodic
`simplify` + smell-audit passes prevent codebase rot (the user's
explicit "ただし … workaround だらけ・設計破壊にしない" constraint).

## Alternatives considered

Devil's-advocate fork (general-purpose subagent, fresh context,
2026-05-29, F-010/F-002/F-003/F-001 envelope) output verbatim:

**Framing.** F-010 fixes *what* (M = Phase 15 完遂 + cw-v0-level narrow ARM64 JIT; post-M quality loop with mandatory refactor gate; wasm-FFI breadth re-sequenced after the loop, F-001 not superseded; v0.1.0 first). F-002 fixes the *quality bar* (finished-form wins; cycle/diff/LOC is not a constraint). F-003 fixes the *who-decides* on structural plans (imagine the full horizon + record as debt scheduled at the owning Phase, **defer** the structural decision to that owner; do not seize). The coupled open question — ROADMAP expression × JIT-vs-coverage sequencing — must land *inside* this envelope. The three shapes below differ only on how aggressively the ROADMAP §9 phase plan is concretised now, and where a coverage-floor sits relative to the JIT.

A constraint-collision finding belongs at the top per the brief: **the full re-number shape (Alt B candidate) is in direct tension with F-003.** Concretely renumbering/inserting Phase 16=JIT-chain, Phase 17+=quality sub-phases, Phase 20+=zwasm *with full task tables now* is decision-seizure on a reservation table (the §9 phase row queue) + dependency graph (JIT vtable seam D-035, `src/eval/backend/jit/` subtree, `runtime/jit/stub.zig`) + responsibility split (quality-loop sub-phase ownership). F-003's scope boundary (principle.md L243-265) says imagination defers *unless an F-NNN already fixes the direction*. F-010 fixes the **direction** (JIT earlier, quality loop standing, zwasm right) but **not the structural granularity** (how many quality sub-phases, their numbering, the JIT subtree extraction shape, the superinstruction-pass module boundary). So the granularity remains an *open structural plan* → F-003 governs → full task-table expansion now is the thing F-003 forbids. This does not halt the loop; it ranks the full re-number below the deferring shapes.

### Alt A — smallest-diff: minimal re-label of §9.18+ headers, everything else deferred

(a) **Concrete.** Edit only the §9.18-9.22 placeholder *headers* + Phase-tracker rows 16-20 names/exit-criteria to reflect the new direction (16 → superinstruction/fusion + JIT go/no-go + narrow ARM64 JIT; 17+ → quality-elevation loop; zwasm/cljs slide to a later row). Add one §14 decision-point reference cross-linking F-010. Leave all task-table expansion (the `[ ]` rows) to each phase's entry owner per the Phase-open procedure. No coverage-floor recorded as a JIT prerequisite — left implicit. Touches ~6 header lines + tracker table.

(b) **Better.** Maximally honours F-003 (pure imagine-record-defer, zero seizure). Smallest audit surface; the §9 tracker stays a "now snapshot" per §17. Cheap to amend again when surveys sharpen.

(c) **Breaks/risks.** Under-records the load-bearing finding from the cw v1 coverage survey: the runtime **cannot run real Clojure code** (interop `.`/`new`/`set!` unimplemented; `get-in`/`assoc-in`/`concat`/`mapcat` missing — D-126/127; seqs eager not lazy). A bare header re-label loses the *prerequisite relationship* between coverage and the JIT. A future Phase-16 owner could read "narrow ARM64 JIT" and land a JIT on a runtime that can't exercise it beyond `arith_loop` — exactly cw v0's 1.0x-on-`fib_recursive` trap, now with no daily-driver code to even reach the hot loop. That is a foresight gap F-003 *requires* the current loop to record (record ≠ seize). So Alt A is too thin: it defers the *decision* correctly but skips the *imagination-recording* duty.

### Alt B — finished-form-clean: light re-label + **debt-recorded foresight** (recommended)

(a) **Concrete.** As Alt A's header/tracker re-label, **plus** the F-003 imagination-recording the survey demands, expressed as debt rows + cross-refs, not as seized task tables:
- Re-aim §9.18 Phase 16 header: "superinstruction/fusion pass → JIT go/no-go → narrow ARM64 JIT (cw-v0-level, M-completing)". Move zwasm-v2/cljs content (current §9.18 body + D-036/037/038/039 entry debts) to a later placeholder (e.g. §9.20+), retaining F-001 "eventual" status — **no renumber of the structural body, just a header re-aim + a pointer that the zwasm entry-debt cluster relocates at its owning entry**.
- Re-aim §9.19+ as the post-M quality-elevation loop placeholder (coverage / clojuredocs-differential / corpus / fuzzing / `docs/works/` + refactor gate), **header + Deliverables prose only**; the repeatable sub-phase structure (how many passes, numbering, ownership) is logged as a **new debt row** "quality-loop phase structure — open, decide at M-exit entry" so the owning entry resolves it (F-003 defer).
- Record the coverage-floor↔JIT relationship as a **debt row + an Entry-debt line on the re-aimed Phase 16 placeholder**: "JIT prerequisite: daily-driver coverage floor (interop syntax `.`/`new`/`set!`; `get-in`/`assoc-in`/`concat`/`mapcat` D-126/127; true lazy-seq) must be green so the JIT lands on a runtime that runs real code — the *ordering* of this floor vs the superinstruction pass is the Phase-16 entry owner's call." This **records the prerequisite (imagination)** without **deciding the ordering (seizure)** — the exact F-003 split.
- Add the superinstruction/fusion-pass module-boundary question (generic opcodes → no arith superinstructions; raw-opcode-window matcher vs fusion pass; route via `runtime/jit/stub.zig` injected vtable per D-035) as a foresight note on the §9.19 (Phase 17) Entry-debt line, deferred to that owner.
- §14: re-aim 14.1 (JIT go/no-go now M-internal, not post-Phase-17 gated) + add a short F-010 cross-ref; leave 14.2/14.3/14.4 as-is (they are genuine future toggles).

(b) **Better.** This is the only shape that satisfies **both** halves of F-003: defers every structural *decision* to the owning entry **and** discharges the imagine-record duty so the future owner inherits foresight, not a blank slate (principle.md L271-301). It directly answers the coverage-floor question — recorded as a prerequisite, ordering deferred — preventing a JIT-on-dead-runtime mistake without seizing the ordering call. It keeps F-001's audit trail clean (zwasm entry-debt cluster relocates intact, not deleted). Finished-form-clean per F-002: the §9 tracker ends up telling the truth about direction while staying a deferring placeholder.

(c) **Breaks/risks.** More moving parts than Alt A (several debt rows + entry-debt lines + a placeholder relocation) — a reviewer could mistake the debt-row volume for seizure. Mitigation: every row is phrased "open — decide at <owning entry>", which is recording, not deciding. Second risk: relocating the zwasm/cljs §9.18 body to a later number is itself a light touch on the row queue (a reservation table) — but it is a *direction* move fixed by F-010, so it falls inside F-003's "F-NNN fixes the direction → implement it" boundary, not the open-plan branch. Keep the relocation to a header/pointer move; do **not** renumber the zwasm task body or its D-036..039 internals (that stays the owning entry's call).

### Alt C — wildcard: insert an explicit "Phase 15.5 — coverage floor / real-code gate" as a hard M-prerequisite, JIT strictly after it

(a) **Concrete.** Beyond Alt B's re-label, **decide the ordering now**: insert a named gate phase between Phase 15 and the JIT — daily-driver coverage cluster + interop syntax + true lazy-seq must be green (a measurable "runs real clojuredocs `:examples` at ≥X%") *before* the superinstruction pass + JIT open. Renumber so JIT becomes Phase 16-after-the-gate. Expand the gate's task table now (pull D-126/127 + interop + lazy-seq rows in).

(b) **Better.** Strongest protection against the JIT-on-dead-runtime failure: makes "real code runs" a literal blocking gate, not a deferred note. Arguably the most *finished-form-sensible* engineering sequence — you do not optimise a runtime that cannot run the programs the optimisation targets. Gives the JIT a real workload (clojuredocs corpus) to bench against beyond `arith_loop`.

(c) **Breaks/risks.** **This decides the coverage-vs-JIT ordering on the owning entry's behalf — F-003 decision-seizure**, and expands a task table now (the same forbidden move as the full re-number). F-010 leaves the *ordering* explicitly with latitude ("M = Phase15+JIT" fixes membership, not internal order); seizing it here is precisely the structural decision F-003 reserves for the M-window entry owner. Also risks scope-creeping the quality loop *into* M (the coverage floor is a slice of the post-M quality loop pulled forward as a gate) — entangling the M definition with the standing loop F-010 keeps separate. The right shape is to **record** this as the leading option for the Phase-16 entry owner (Alt B's debt row), not to **enact** it now.

### Non-binding recommendation (anchored to F-002 + F-003)

**Take Alt B (light re-label + debt-recorded foresight).** It is the finished-form-clean shape *and* the F-003-compliant shape simultaneously — rare alignment, so the Cycle-budget defer smell does not even arise (no smaller-diff downgrade is being recommended; Alt A is *worse* on finished-form because it under-records foresight, not merely smaller). On the two explicit sub-questions:

1. **Light re-label + defer per F-003 beats the full re-number** — yes, decisively. The full re-number (and Alt C) seize structural decisions (row queue, JIT subtree, quality sub-phase structure, coverage/JIT ordering) that F-010 leaves at *direction*, not *granularity*; F-003 reserves granularity for the owning entry. The "finished-form wins" instinct (F-002) might tempt enacting Alt C's clean ordering now — but F-002 governs *code/design quality*, while F-003 governs *who decides structural plans*; they do not conflict here because deferring the decision does **not** lower the finished-form quality (the owner decides with more context). Picking Alt C "because it's the cleaner sequence" would be reading F-002 as a license to override F-003 — it is not.

2. **The ROADMAP should record the coverage-floor as a JIT prerequisite** — yes, as a **debt row + Entry-debt line on the re-aimed Phase 16 placeholder**, framed "prerequisite recorded; ordering deferred to the Phase-16 entry owner." This is the load-bearing finding (runtime can't run real code today) that F-003 *obligates* the current loop to surface as foresight. Recording it is imagination-discharge, not seizure; deciding the floor-vs-superinstruction ordering is seizure → leave it to the owner. Same for the superinstruction/fusion-pass module boundary and the D-035 JIT-vtable extraction — record as foresight on the Phase-17 entry-debt line, defer the shape.

The one thing to guard against while landing Alt B: keep the zwasm/cljs relocation a header/pointer move (direction fixed by F-010 → implement) and resist letting the debt-row volume tip into pre-deciding the quality-loop sub-phase structure (granularity open → defer).

## Selection rationale

Alt B selected. It is simultaneously finished-form-clean (F-002) and
F-003-compliant — it discharges the imagine-record duty (the runtime
can't run real code today → coverage-floor recorded as a JIT
prerequisite) while deferring every structural *decision* (renumber,
quality-loop sub-phase structure, floor-vs-superinstruction ordering)
to the owning Phase entry. Alt A under-records foresight; Alt C seizes
the coverage-vs-JIT ordering that F-003 reserves for the owning entry.
The F-002-instinct to enact Alt C's clean ordering now is explicitly
rejected: F-002 governs design quality, F-003 governs who-decides;
deferring does not lower finished-form quality (the owner decides with
more context).

## Consequences

- ROADMAP §9 gains a re-sequencing note (after §9.16) recording the D1
  order; the §9.2 v0.x milestone mapping is annotated superseded-by-F-010.
- Debt rows D-131 (ADR-0034 deferred build blocks, from the D-100(b)
  cycle) / D-132 (quality-loop phase structure) / D-133 (JIT
  coverage-floor prerequisite) minted.
- `.dev/reference_clones.md` gains the Quality-elevation corpora
  (`clojure-corpus` + `clojuredocs-export-edn`).
- No phase renumber lands now; the M-exit entry owner concretises the
  quality-loop phases + the JIT/coverage ordering with full context.
- F-001 retains "eventual unavoidable" status; the zwasm/CLJS entry-debt
  cluster (D-036..039) relocates intact at its owning entry, not deleted.
- v0.1.0 (Phase 14) is unaffected — it completes first; D-100(b)
  `cljw build` remains its in-flight deliverable.

## Affected files

- `.dev/project_facts.md` — F-010 (the governing invariant; landed same
  session).
- `.dev/ROADMAP.md` — §9 re-sequencing note + §9.2 annotation + light
  pointers on the Phase 16/17/19/20 tracker context + §14.1 F-010 cross-ref.
- `.dev/debt.md` — D-131 / D-132 / D-133 rows.
- `.dev/reference_clones.md` — Quality-elevation corpora section.
- `private/notes/recut-goal-synthesis.md` + the 3 surveys — grounding.

## Revision history

- 2026-05-29 issued + accepted with Devil's-advocate fork
  (general-purpose, fresh context, F-010/F-002/F-003/F-001 envelope, 3
  alternatives verbatim, Alt B selected). Records the user-directed
  interim-goal re-cut (F-010) as a ROADMAP §9 re-sequencing expressed
  per F-003 (light re-label + debt-recorded foresight, granularity
  deferred to owning Phase entries).
