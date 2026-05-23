---
paths:
  - ".dev/handover.md"
---

# Handover framing discipline

Auto-loaded when editing `.dev/handover.md`. Codifies the cw v1
2026-05-23 retrospective + the matching zwasm v2 rule
(`~/Documents/MyProducts/zwasm_from_scratch/.claude/rules/handover_framing.md`).

Two failure modes have repeatedly bloated cw's handover:

1. **Log accumulation** — successive "Just landed — §X" sections
   pile up across sessions; the file becomes a session diary
   redundant with `git log`.
2. **Surrender framing** — phrases like
   "コンテキスト圧があるため一旦 idle に入る" /
   "キリがいい" / "自然な区切り" turn the resume entry point
   into a stop signal that the closed 3-condition list (CLAUDE.md
   § Autonomous Workflow) does not authorise.

## The rule

`.dev/handover.md` is a **driving document**, not a
**deliberation document** or **session log**. Every entry must
either:

1. Describe the concrete **next task** the resume should execute
   (§9.<N>.<M> identifier + retrievable file/section pointers), OR
2. Name a **provable external blocker** with a testable barrier
   condition (already a `debt.md` row by default — handover only
   names the row by ID).

Anything else is forbidden framing. The loop reads handover to
decide **what to do next**, not whether to do anything.

## Hard length limit: ≤ 100 lines

Above 100 lines, the framing has drifted into log / deliberation /
forecast. Trim before commit. `git log` and `.dev/ROADMAP.md`
already carry the history and the forecast.

## Forbidden patterns (grep-enforceable)

The following appearances anywhere in `.dev/handover.md` are
**block-level findings** that resume Step 1 (`/continue`) must
repair before proceeding.

### Phrase-level (surrender / stop-rationalisation framing)

| Phrase                                          | Why forbidden                                                                     | Replace with                                                                                                                    |
|-------------------------------------------------|-----------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `コンテキスト圧があるため` (and variants)       | Auto-compaction is system-handled; not an agent concern                           | Just describe the next task                                                                                                     |
| `キリがいい` / `自然な区切り` / `natural break` | Implies a stop point the closed 3-condition list does not authorise               | Drop entirely                                                                                                                   |
| `good stopping point` / `この辺で一旦停止`      | Same                                                                              | Drop entirely                                                                                                                   |
| `Phase boundary reached AND ...`                | Phase boundary is no longer a stop condition per CLAUDE.md § Autonomous Workflow | Drop the "AND" clause; phase close runs review chain then continues into §9.<N+1>                                              |
| `If above ~60%` / `/compact` / `context budget` | Compact-gate concept removed; `/compact` is not Skill-tool callable               | Drop; auto-compaction is transparent                                                                                            |
| `〜判断待ち` (without named ADR / debt row)     | Generic surrender; the closed stop list requires a named ADR-level decision       | Either name the specific ADR row in `.dev/decisions/` OR file a `debt.md` row with `Status: blocked-by: <named external event>` |

### Structural (log / forecast / reproduced-content accumulation)

| Pattern                                                          | Why forbidden                                                                            | Replace with                                                                                                |
|------------------------------------------------------------------|------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------|
| More than **one** `## Just landed` section                       | Log accumulation; `git log` is the SSOT                                                  | Keep at most the most-recent landing as a single ≤ 10-line section, or drop entirely once next task starts |
| `## Future ... shopping list` / forecast tables                  | Forecast belongs in `.dev/debt.md` (recall trigger row) or ROADMAP §A / ADR governance  | Move to debt.md as a `D-NNN` row with `Status: recall trigger` and remove from handover                     |
| `## Notes for the next session` reproducing rule / skill content | CLAUDE.md / `.claude/rules/` / skill `SKILL.md` are the SSOT — auto-loaded each session | Drop; the next session re-reads the source SSOT                                                             |
| Numeric predictions (`~N tasks remain`, cycle counts)            | Per `no_handover_predictions.md`                                                         | Concrete identifiers (`next: §9.6 / 4.4`); no counts                                                       |
| Multi-paragraph editorial framing of work size                   | "deep work" / "substantial multi-cycle" / "重い" framings are stop rationalisations      | Just name the task and the entry ADR                                                                        |

## What handover IS for

- **Cold-start reading order** (≤ 3 files; the first is handover
  itself) so a fresh session reaches the active task in < 30 sec.
- **Current state** — phase number, branch, last commit, gate
  status (1-line summary; not a changelog).
- **Active task** — §9.<N>.<M> identifier + 1-2 sentence
  description + retrievable identifiers (ADR refs, file paths,
  test name).
- **Next phase queue** — only when the current phase is within a
  task or two of closing AND the next phase's entry items are not
  already in §9.<N+1> placeholder.
- **Open questions / blockers** — testable external dependencies
  only; otherwise the row belongs in `.dev/debt.md`.

## What handover IS NOT for

- Listing past landings (`git log --oneline` is the SSOT).
- Listing future ADRs / debts / refactors (debt.md and ROADMAP
  §A are the SSOTs).
- Re-explaining rules / skills / output styles (the SSOT files are
  auto-loaded each session).
- Multi-option pickup menus — pick the one option in handover
  itself.
- "Cycle 1 did X, cycle 2 did Y" running log (per-task notes in
  `private/notes/` are the SSOT and are gitignored).

## Reviewer checklist

When reviewing a handover.md commit:

- [ ] ≤ 100 lines total.
- [ ] No phrase from the forbidden-phrase table.
- [ ] At most **one** `## Just landed` section.
- [ ] No forecast / shopping-list table.
- [ ] `Active task` names a concrete next §9.<N>.<M> task, not
      an option list.
- [ ] `Open questions / blockers` rows are either testable
      external blockers OR already mirrored as `.dev/debt.md`
      D-NNN rows (named here by ID).
- [ ] No numeric predictions (per
      [`no_handover_predictions.md`](no_handover_predictions.md)).

## How `/continue` enforces this

The resume procedure (Step 1) scans handover for length + forbidden
phrases:

```sh
wc -l .dev/handover.md   # warn if > 100
grep -nE 'コンテキスト圧があるため|キリがいい|自然な区切り|natural break|good stopping point|この辺で一旦停止|Phase boundary reached AND|If above ~60%|context budget|/compact' .dev/handover.md
grep -c '^## Just landed' .dev/handover.md   # warn if > 1
grep -nE '^## Future .* shopping list|^## Notes for the next session' .dev/handover.md
```

On any hit → the FIRST task of the resume is the handover rewrite
itself, not the prose-suggested next task. Then the loop proceeds
normally.

This is by design: the framing fix is cheap (~5 minutes) and
catastrophic to skip — a single forbidden section can cost a
session of mis-anchored work.

## Legitimate stop framing

When the closed 3-condition stop list (CLAUDE.md § Autonomous
Workflow) genuinely fires, handover names the gating condition
concretely:

```markdown
## Stopped — user touchpoint required

Autonomous loop stops per CLAUDE.md § Autonomous Workflow
condition 2 (ADR-level decision).

**Gating decision**: ADR-NNNN (`.dev/decisions/NNNN_<slug>.md`)
`Status: Proposed → Accepted` flip. After flip, loop resumes at
§9.<N>.<M>.

**Autonomous prep walked this resume** (do not re-walk):
- ADR-NNNN References enriched: <commit-sha>.
- ADR-NNNN Consequences refined: <commit-sha>.
```

This is NOT forbidden framing — it is the encoded artefact of
"all autonomous levers pulled; the remainder genuinely needs you".
The forbidden phrases above target the **opposite** failure
mode (defer without walking the levers).

## Stale-ness

This rule is stale if:

- The forbidden-phrase table no longer matches actual handover
  drift. Re-derive from
  `git log -p .dev/handover.md --since="90 days ago"` and surface
  new euphemisms.
- The closed 3-condition stop list in CLAUDE.md § Autonomous
  Workflow changes; the "Legitimate stop framing" section above
  must mirror the canonical wording.

## Related

- [`no_handover_predictions.md`](no_handover_predictions.md) —
  forbids numeric / behaviour predictions (sibling rule).
- CLAUDE.md § Autonomous Workflow — the closed 3-condition stop
  list this rule references.
- `~/Documents/MyProducts/zwasm_from_scratch/.claude/rules/handover_framing.md`
  — the v2 source rule cw adapted from.
