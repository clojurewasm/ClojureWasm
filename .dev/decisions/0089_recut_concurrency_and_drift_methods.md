# ADR-0089 — post-M re-cut (A→B→C), §7 concurrency drift + redesign-deferral, drift-detection method

Status: Proposed → Accepted
Date: 2026-06-04
Supersedes-in-part: §9.2.R sequencing wording (this ADR records the restore);
amends ROADMAP §7.1 / §7.2 / §9.2.S / §9.16-14.13.5.

## Context

User-directed re-cut (2026-06-04 chat). Two drivers:

1. **The clean-bounded clj-parity frontier is drained.** This session ran the
   F-010 post-M quality-elevation loop deep into `clojure.core` + print-control +
   regex; a 40+ idiom broad probe came back all-green. The loop now lacks
   bounded wins — every remaining `clojure.core` gap is deep / owner-gated /
   long-tail.

2. **Doc/debt drift accumulated where the user predicted** (audit
   `private/audit-2026-06-04.md`): the ROADMAP re-cut sections (§9.2.R/§9.2.S),
   the v0.1.0 row (14.13.5), and especially **§7 (concurrency)** describe a plan
   the implementation has overtaken — AND that §7 predates Zig 0.16's stdlib
   removals.

The user's strategic correction: implementing the KNOWN-unimplemented CORE
(concurrency-led) must come **before** library-driven gap-hunting — "if those
aren't implemented, libraries fail en masse, and under progress-pressure they
get slapdash implementations." Do it plan-driven, finished-form, **rework-OK
with test guards** (F-002), aiming at the project identity: a lightweight, fast,
near-full-featured Clojure runtime reaching territory no non-JVM Clojure impl
except Babashka has — real STM / agents / threads in a Zig runtime.

## Decision

### 1. Post-M execution re-cut (restores §9.2.R Phase-15-first intent)

```
Phase A  Consolidation — sweep doc/guard drift, align records to reality.
   ↓     (doc/scaffold-only: no per-item test gate; batch-resolve)
Phase B  KNOWN-unimplemented CORE, concurrency-led: §7 redesign + STM
   ↓     transactions / agent / locking / real threading / Thread interop,
         + Java arrays (F-004) / *out*·*in*·*err* IO vars (D-238) /
         with-local-vars (D-237) / reflection. finished-form, rework-OK.
Phase C  Library-driven gap-hunt (old "Phase B") — on the concurrency-
         capable foundation; workaround remediation folds in here.
```

This is **not new** — §9.2.R already sequenced Phase 15 (concurrency) before the
quality loop. The session had drifted by running the quality loop pre-Phase-15;
this re-cut restores the intended order and names the consolidation pass (A) that
clears the deck first.

### 2. §7 concurrency drift — corrected, redesign DEFERRED to Phase B entry

Verified state (2026-06-04 probes): `future`/`promise`/`delay`/`pmap`/`pcalls`
all run **synchronously** today (`future.zig:10` "eager-inline"); the GC is
**single-threaded** (`arena.zig:14`). Concurrency primitives missing entirely:
`dosync`/`alter`/`commute`/`ensure`/`ref-set` (only the `ref` shell exists),
`agent`/`send`/`await`/`agent-error`, `locking`, `Thread` interop.

Three §7 lies/staleness corrected in ROADMAP (this ADR is the rationale):

- **§7.2 "STM is implemented"** — FALSE. `ref` shell only; the transaction
  machinery is unbuilt (§7.2's own staging table assigns it to Phase 14/15).
  Corrected to "designed (ADR-0010); transactions land in Phase B."
- **§7.1 Zig-mechanism column** references **removed Zig 0.16 APIs**
  (`std.Thread.Pool` / `std.Thread.Mutex` / `Condition`) — per `zig_tips.md`
  these are gone; the real impl must use `std.Io.*` / `std.atomic`. The §7
  mapping is a **pre-0.16, pre-current-architecture design** and must be
  **redesigned at Phase B entry** (its own DA-fork + Structural-imagination per
  §17/F-003), not patched here. The `runtime/binding_stack.zig` reference is dead
  (the binding stack lives in `env.zig`).

Phase B's concurrency design forces revisiting single-threaded assumptions
(GC thread-safety, atom/ref CAS atomicity, threadlocal-binding conveyance to
spawned threads — `bound-fn`/D-241, future/pmap real parallelism). This is the
F-002 rework territory; it is **deferred to Phase B entry with full ADR
discipline**, not decided here.

### 3. Drift-detection method — FOLD into existing homes (no new mechanisms)

The user added a method: exhaustively read **all code comments** to surface
"drift from finished-form" that doc/debt sweeps miss (comments encode
`stub` / `for now` / `single-threaded so fine` / `eager-inline` / `Phase N will`
/ stale-API-refs that were never promoted to `debt.yaml`). Per the mandatory
Devil's-advocate fork (reflected below), this and three sibling proposals are
**folded into existing mechanisms**, NOT added as new ones — adding a §G + a
skill + a rule + an F-013 would contradict the compress-guards goal that is
Phase A's whole point:

- **comment-drift sweep** → widen `audit_scaffolding` **§E2.7** pattern list
  (`stub` / `single-threaded so fine` / `eager-inline` / stale-API), and **run
  it this cycle** (deferring to "a fresh session" is the Defer-to-amnesia smell;
  grep precision is context-independent; `framework_completion.md` mandates the
  sweep-introducing cycle run the sweep). The exhaustive per-comment
  classification (the judgment-heavy half) runs as fan-out subagents (each
  fresh-context by construction) as the first Phase-A work item → promotes
  (b)/(c) findings to debt rows / Phase B inputs.
- **spike-before-structural** (throwaway Zig spikes, web-search + Zig-0.16-source
  to validate a Clojure-equivalent design before the concurrency ADR) → one
  sentence in `principle.md`'s Structural-imagination phase; NOT a new rule
  (Step-0 survey + DA-fork + Structural-imagination + `exploration_vs_done.md`
  freedom already cover it).
- **"user-observable parity, internals free"** → already **F-011 §2** verbatim +
  `no_jvm_specific_assumption.md`. NO new F-013 (duplicate-law bloat; loop-minted
  F-NNN also violates the append-only/user-declared rule). Cite F-011.

## Alternatives considered (Devil's-advocate subagent, verbatim)

Grounding read: project_facts.md (F-001..F-012, esp. F-002/F-009/F-011),
no_jvm_specific_assumption.md, principle.md Bad Smell catalogue
(Framework-incomplete, Defer-to-amnesia, Stale-phase-ref, Reservation-as-bias +
Structural-imagination), audit_scaffolding/CHECKS.md §E2.7, framework_completion.md,
ROADMAP §9.2.R. Confirmed the compress-guards tension is real: 31 rules / 40
scripts / 89 ADRs already standing.

**Choice 1 — comment-drift sweep as new §G: FOLD into E2.7.** E2.7
("telltale-pattern provisional sweep") already greps `src/` + `test/e2e/` for
`for now|stands in for|until Phase N|temporarily|placeholder|TBD`; E2.6 owns the
`Phase N` half; no_jvm_specific_assumption owns the stale-API half. A new §G
duplicates E2.6+E2.7 (the B2 Duplicated-claims condition). The genuine delta
(`stub`/`single-threaded so fine`/`eager-inline`) is a one-line widening of
E2.7's `rg` alternation, not a new mechanism. (a) new skill = worst (a whole
skill for one grep line); (c) run-once = undersells (keep it periodic). Action:
widen E2.7 by ~4 tokens.

**Choice 2 — build-now/run-later (fresh context): RUN NOW.** "fresh context =
more exhaustive" is the Defer-to-amnesia smell almost verbatim; a grep does not
get more exhaustive with empty context — precision is in the regex + classifier
discipline. Deferring couples the drift-finder to "next session," defeating the
Phase A whose point is to drain drift now. framework_completion's counter-example
is exactly "ship a matcher without running it against the current tree." Run it
in the Phase A cycle that widens E2.7.

**Choice 3 — spike_before_structural.md rule: DROP rule, FOLD note.** Design
rigor for Phase B is already triple-covered (Step-0 survey incl. Zig stdlib, the
depth≥2 DA-fork, principle.md Structural-imagination). A rule asserting "spikes
are allowed" mostly grants a permission that already exists (exploration_vs_done
+ ~/.claude/CLAUDE.md "気軽に実験コードを作ってよい"). A new paths-scoped rule
would itself trigger framework_completion (discovery + sweep + retrofit) — a
disproportionate landing cost for near-zero new constraint. The one useful nugget
("validate the Zig-0.16 primitive in a spike before committing the ADR shape")
belongs in principle.md's Structural-imagination phase. Append a sentence; no
32nd rule.

**Choice 4 — F-013 promotion: DROP, sharpen F-011 if anything.** Already F-011 §2
nearly verbatim ("Behavioural equivalence is the correctness target; internals
are free … observable input→output incl. error cases must match real Clojure;
internal mechanics + representation may diverge freely"), with
no_jvm_specific_assumption as its operational arm. A new F-013 = the same
project-law in two F-NNN entries (B2 + anti-duplication), inviting drift + a
"which wins" decision. F-NNN entries are user-declared + append-only, amended
only by user direction; minting F-013 to restate an existing fact would be the
loop manufacturing project-law on its own — barred by the priority-order header.
Action: nothing, or a user-directed one-line sharpening of F-011 §2 — never a new
F-013.

**Cross-cutting:** all four "add a mechanism" instincts fail the compress-guards
default for the same reason — each one's novel content is a 1-3 line widening of
an existing mechanism, and the existing audit/rule/F-NNN homes are already the
canonical owners. Phase A is better served by *tightening the four existing
homes* than by adding §G + a skill + a rule + an F-NNN.

## Consequences

- Phase A wiring is LEAN: ROADMAP alignment + E2.7 widen (+run) + a principle.md
  sentence + handover + debt rows. No new rule, no new skill, no new F-NNN.
- Phase B is the project's largest + hardest unit (real concurrency in Zig); it
  opens with a §7-redesign ADR + Structural-imagination + DA-fork at its entry.
- The §7.2 STM-lie and §7.1 stale-API are corrected in ROADMAP (drift removed).
- Per-item test gating is dropped for Phase A's doc/scaffold work (user-directed:
  "こまめなテストはかえって遅くなる").

## Affected files

- `.dev/ROADMAP.md` §9.2.R / §9.2.S / §7.1 / §7.2 / §9.16-14.13.5.
- `.claude/skills/audit_scaffolding/CHECKS.md` §E2.7 (pattern widen).
- `.dev/principle.md` (Structural-imagination: spike-the-primitive sentence).
- `.dev/handover.md` (resume = Phase A).
- `.dev/debt.yaml` (それ-tier rows; §7.2-lie tracking; discharged sweep).
