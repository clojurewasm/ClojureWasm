# 0168 — Reconcile ROADMAP's operating-model text with the autonomous loop; rescope inviolable principle P1

- **Status**: Proposed → Accepted
- **Date**: 2026-07-01
- **Author**: the ClojureWasm authors
- **Tags**: governance, roadmap, autonomous-loop

## Context

The round-2 multi-agent quality audit (find → adversarially verify → synthesize)
surfaced a coherent **stale-operating-model cluster** in `.dev/ROADMAP.md`: the
file still describes an *older* operating model that later decisions superseded,
while the loop already follows the newer model documented in CLAUDE.md
(`.claude/CLAUDE.md`). Concretely:

- **Inviolable principle P1** (§2, table row) reads *"Move forward only with
  understanding — Interactive Claude Code use. No overnight batch commits."* The
  project's **default is continuous autonomous execution** (CLAUDE.md
  § Autonomous Workflow / § The only stop), and the user has repeatedly directed
  overnight / batch autonomous work.
- **§0 / §12.4** state the loop has **two** stop conditions ("explicit user
  request, or a physical block = unrecoverable build/test failure"); CLAUDE.md
  § The only stop declares exactly **one** (explicit user request) and states
  "Test failure / gate red — does not stop."
- **§0 / §16** present the retired **phase-queue / "expand §9.<N+1>
  placeholder"** model as active (retired by ADR-0142 → gap-area I/II/III +
  easiest-first debt drain).
- **§12.4** labels the per-commit gate **"Mac+Linux"** (Linux is boundary-only
  per ADR-0049; the gate is two-tier smoke/full per ADR-0107).
- Minor drift: §0 says "25 ADRs" (now 168), and "ARCHITECTURE.md" (moved to
  `docs/architecture.md`).

The user directed both remedies: (1) fix the §0/§12.4/§16 live-procedure
contradictions via a ROADMAP §17 in-place amendment; (2) rescope P1 via this ADR
so continuous autonomous execution is canonical.

Per the project priority chain (`project_facts.md`), the only allowed
reconciliation direction is to align the lower-priority doc (ROADMAP) **up** to
law (F-NNN) and to CLAUDE.md — never the reverse.

## Decision

1. **Rescope P1 (keep the name/intent, rewrite the Effect).** P1 stays *"Move
   forward only with understanding."* Its Effect becomes: *"Continuous autonomous
   execution is the default (CLAUDE.md § Autonomous Workflow); overnight / batch
   autonomous commits are expected. 'Understanding' is enforced per-commit by the
   two-tier gate (ADR-0107) + the mandatory Step-6 `Smell-audited:` audit + P9
   (never commit red) — not by human interactivity."* The genuine safety intent
   of the old clause (don't ship code the loop cannot explain) is **relocated**
   to the gate + smell-audit, not deleted.

2. **Collapse the stop model to one condition.** The loop stops only on
   CLAUDE.md § The only stop's single condition (explicit user request). The
   former second condition ("physical block") is not removed behaviourally — its
   intent already lives elsewhere: gate-red → **diagnose and fix in-flight**
   (does not stop); a genuinely underivable external fact (credential / product
   preference) → **in-task `AskUserQuestion`**, not a session stop.

3. **Declare CLAUDE.md the SSOT for the loop procedure + stop model.** ROADMAP
   §12.4's 7-step table is retained as a **cold-start quick-ref explicitly marked
   derivative** ("change the procedure in CLAUDE.md, not here"), and its stale
   cells are fixed (gate label → "Mac smoke per-commit; full + Linux batched";
   two → one stop condition). This resolves the authority-drift (the defect that
   caused this ADR) while keeping the readable inline table and minimising
   cross-reference risk. **Depth-vs-authority split (deliberate):** the SSOT for
   the *procedure* is intentionally the lower-priority CLAUDE.md, while the
   *authority to change the model* stays with ROADMAP / ADR / F-NNN — a future
   reader must not "fix" this back into ROADMAP.

4. **Retire the phase-queue prose.** §0 and the §16 glossary "Phase open
   procedure" row are updated to the gap-area self-selection model (ADR-0142);
   the dead glossary row is struck, not merely re-pointed. Stale §0 counts/paths
   are fixed as a byproduct (Step 0-8 → 0→7; Next Phase Queue → First task on
   resume; 25 ADRs → "the ADRs"; ARCHITECTURE.md → docs/architecture.md).

## Alternatives considered

The mandatory Devil's-advocate subagent (fresh context, F-002/F-009 + the
priority chain grounded) produced the following, reflected verbatim:

> **Leading finding — F-NNN block: NONE.** No active F-NNN forbids any shape
> below. F-002 (finished-form wins over smallest-diff) *disfavours* the
> smallest-diff option: choosing the minimal line-patch on cycle-budget grounds
> would itself be the Smallest-diff-bias smell F-002 names. F-009 is irrelevant
> (no feature-neutrality surface). The autonomous model is already the default
> per CLAUDE.md, so making it canonical aligns a lower-priority doc up to law +
> CLAUDE.md — the only allowed direction. One structural nuance to record (not a
> block): CLAUDE.md says "if anything conflicts with the roadmap, the roadmap
> wins," yet §0/§12.4 *already* delegate the step-by-step spec to CLAUDE.md — so
> a pointer-to-CLAUDE.md shape is consistent with existing practice, but the ADR
> should state that the SSOT for the *procedure* is intentionally the
> lower-priority doc while the *authority to change the model* stays with
> ROADMAP/ADR/F-NNN (a deliberate depth-vs-authority split).
>
> **Shape A — Smallest-diff: line-by-line in-place patch.** Rewrite only the
> wrong cells. Better: minimal blast radius, locally auditable, honours §17
> "edit in place." Breaks: preserves the **root defect** — §12.4 keeps
> *duplicating* the loop procedure CLAUDE.md owns; two copies of a living
> procedure drift again (this ADR exists because they drifted). Under F-002 this
> lands a dirtier finished form (two copies), so cycle-size cannot justify it.
>
> **Shape B — Finished-form-clean: SSOT consolidation (RECOMMENDED).** Make
> CLAUDE.md the sole SSOT; reduce §12.4 to a pointer; rewrite P1's Effect (keep
> the name), collapse to one stop condition, delete the retired phase-queue
> prose in §0/§16, fix stale counts/paths. Better: eliminates the duplication
> class permanently (the redundancy finding is *resolved*, not patched); one
> place to change the model; priority chain reads cleanly. Recommended even
> though its diff is larger — cycle/LOC is not a constraint. Risks: (1) a reader
> on §12.4 no longer sees the procedure inline (mitigate with an explicit
> pointer; §0 already routes to CLAUDE.md first); (2) the priority-inversion
> nuance becomes load-bearing (must be stated); (3) larger edit = enumerate every
> §16/§15 dependent or a stale glossary row survives.
>
> **Shape C — Wildcard: preserve P1 by *narrowing*, not overwriting.** Keep P1
> with its Effect narrowed to the surviving safety kernel; add a new principle
> "Continuous autonomous execution" carrying the overnight-batch mandate + a
> "supersedes P1's former interactive clause" note. Optionally promote the
> autonomous model to a fresh F-NNN so it stops being re-litigated at ROADMAP
> level. Better: makes the intent surgery legible (which part of P1 died vs
> survived). Breaks: two principles cover one topic (principle-count inflation);
> the F-NNN-promotion half is **not loop-decidable** (needs user direction +
> Revision-history entry per project_facts.md); cuts slightly against §17's
> edit-in-place house style.
>
> **Recommendation (non-binding): Shape B, with Shape C's intent-preservation
> discipline.** (1) Rewrite P1's Effect but do NOT merely delete "No overnight
> batch commits" — relocate its genuine intent (don't ship code you don't
> understand) explicitly onto the gate (ADR-0107) + Step-6 smell-audit + P9. (2)
> Collapse 2→1 stop conditions but say where the old second went (gate-red →
> diagnose-and-fix; underivable external fact → in-task AskUserQuestion). (3)
> Consolidate §12.4 to a pointer and strike the dead §16 glossary row.

**Chosen:** Shape B's SSOT-consolidation intent + Shape C's intent-preservation
(findings 1-2), with one adjustment: §12.4's 7-step table is **kept as a
derivative quick-ref carrying an SSOT pointer** rather than fully gutted to a
bare pointer. Rationale (not cycle-budget — F-002-clean): a derivative table
with a declared SSOT + "change it in CLAUDE.md" note is itself a clean finished
form (SSOT declared, drift-authority removed), keeps the cold-start quick-ref
readable, and minimises the §15/§16 cross-reference risk the DA flagged for full
gutting. The DA's full-B (gut to pointer) and the Shape-C F-NNN promotion remain
available as user-owned follow-ups.

## Consequences

- **Positive**: ROADMAP's operating-model text matches reality; the autonomous
  model is canonical at principle level; the loop-procedure SSOT is single
  (CLAUDE.md) with the authority-to-change staying at ROADMAP/ADR/F-NNN; the
  redundancy finding is addressed via the SSOT pointer.
- **Negative**: §12.4 retains a derivative table (a small, marked duplication)
  rather than a bare pointer — accepted for readability; the SSOT pointer guards
  against re-drift.
- **Neutral / follow-ups**: (a) promoting the autonomous-execution model to a
  fresh **F-NNN** is a user-owned option (per DA Shape C) the loop surfaces but
  does not self-execute. (b) The broader "make CLAUDE.md the *sole* inline
  procedure and gut §12.4" (full Shape B) can be revisited on user request.

## Affected files

- `.dev/ROADMAP.md` §0 (reading-order + step-count + stop-framing + ADR-count +
  paths), §2 (P1 Effect), §12.4 (gate label + single stop condition + SSOT
  pointer), §16 (glossary "Phase open procedure" struck) — amended in place per §17.
- `.dev/decisions/0168_reconcile_operating_model_p1_rescope.md` — this ADR.
- `.dev/handover.md` — synced (§17 step 3).

## References

- ROADMAP §0 / §2 / §12.4 / §16 (amended); §17 amendment policy.
- Related ADRs: ADR-0142 (phase-queue retired → gap-area model), ADR-0107
  (two-tier smoke/full gate), ADR-0049 (Linux gate boundary-only), ADR-0025
  (chapter cadence dormant).
- CLAUDE.md § Autonomous Workflow / § The only stop (the loop-procedure SSOT).
- `project_facts.md` F-002 (finished-form wins) + the priority chain.

## Revision history

- 2026-07-01: Status: Proposed → Accepted (initial landing). Surfaced by the
  round-2 quality audit; Devil's-advocate output reflected above.
- 2026-07-01: Amended (user-authorized) — folded in the **P3** truth-fix (§2 Effect
  "Extensions go to `modules/`" → "`src/lang/clj/` or pods"; `modules/` retired) and the
  D-547 ROADMAP relabels (`check_adr_history` → on-demand audit; the 4 scripts' retired
  "Phase 5 promotion" → on-demand). Same operating-model-reconciliation theme; P3 is a
  truth-fix (intent unchanged), not a rescope, so no separate DA fork.
