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
   into a stop signal that CLAUDE.md § The only stop does not
   authorise. The only stop is the user's explicit request, and
   that record lives in `## Stopped — user requested` with the
   user's verbatim quote — not as a euphemism in the body.

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

| Phrase                                                                                              | Why forbidden                                                                                                       | Replace with                                                                                                           |
|-----------------------------------------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `コンテキスト圧があるため` (and variants)                                                           | Auto-compaction is system-handled; not an agent concern                                                             | Just describe the next task                                                                                            |
| `キリがいい` / `自然な区切り` / `natural break`                                                     | Not a stop condition. The only stop is user explicit request                                                        | Drop entirely                                                                                                          |
| `good stopping point` / `この辺で一旦停止` / `region boundary stop` / `task boundary stop`          | Same — region / cluster / task / commit boundaries all roll into the next unit of work                             | Drop entirely                                                                                                          |
| `Phase boundary reached AND ...`                                                                    | Phase boundary is not a stop. The review chain runs and the loop continues into §9.<N+1>                           | Drop the "AND" clause                                                                                                  |
| `If above ~60%` / `/compact` / `context budget`                                                     | Compact-gate concept removed; `/compact` is not Skill-tool callable                                                 | Drop; auto-compaction is transparent                                                                                   |
| `〜判断待ち` / `user 確認待ち` / `awaiting user confirmation` / `awaiting approval`                 | "Awaiting user" is not a stop state. Push is automatic; ADR-level designs are handled inline                        | Drop; if a real external block, file a `debt.md` row with `Status: blocked-by: <named external event>` and name it     |
| `cannot be self-decided` / `human judgement` / `human judgment` / `needs human` / `user touchpoint` | The loop self-decides design choices; "needs human" reframes a self-decidable case as a stop                        | Drop entirely; if the design is genuinely ADR-level, draft + accept the ADR inline per CLAUDE.md and link the ADR slug |
| `this needs human judgement` / `help wanted` / `awaiting human review` / `defer to user`            | Same family — invites a pause for human input that is not a stop condition                                         | Drop entirely                                                                                                          |
| `ADR-level decision` / `ADR-phase mode` (as a stop reason)                                          | ADR-level designs are inline work. Smell-driven ADR drafting is an interrupt, not a stop                            | Rewrite as an Active task entry naming the candidate ADR slug + the F-NNN-compliant shape the AI is taking             |
| `smell-cluster trip` / `smell cluster` / `patterned smell` / `goal drift trip`                      | Smell triggers are interrupts, not stops. No frequency-counter rule exists                                          | Drop entirely; the surgery already landed inline at the interrupt                                                      |
| `physically blocked` / `physical block` (when build / test failures are involved)                   | Build / test failure is not a stop condition either. Diagnose and fix; the loop owns getting back to green          | Drop the "block" framing; describe the failure as the current Active task with the diagnosis attempted                 |
| `stopped — physical block` / `Stopped — physical block`                                           | No such stop condition exists                                                                                       | Rewrite into Active task naming the failing test / build artifact and what to try next                                 |
| `physical block / blocker` as a *non-debt-row* reason in handover                                   | All real external blocks live in `debt.md` with a `blocked-by: <event>` Status; handover names the D-NNN by ID only | Move to `debt.md`, reference here as `D-NNN`                                                                           |

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
grep -nE 'コンテキスト圧があるため|キリがいい|自然な区切り|natural break|good stopping point|この辺で一旦停止|region boundary stop|task boundary stop|Phase boundary reached AND|If above ~60%|context budget|/compact|user 確認待ち|awaiting user confirmation|awaiting approval|cannot be self-decided|human judgement|human judgment|needs human|user touchpoint|help wanted|awaiting human review|defer to user|ADR-level decision|ADR-phase mode|smell-cluster|smell cluster|patterned smell|goal drift trip|physically blocked|physical block|Stopped — physical block' .dev/handover.md
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

There is only one legitimate stop and only one section shape for
recording it. Per CLAUDE.md § The only stop:

> The user explicitly asks the loop to stop.

Record the directive verbatim (or close paraphrase) under
`## Stopped — user requested` so the next session reads back
exactly what was asked. The directive applies to the session in
which it was issued; the next `/continue` (or any automated
re-invocation) resumes the loop normally:

```markdown
## Stopped — user requested

User instruction (2026-MM-DD): "<verbatim or close paraphrase>".
Resume at §9.<N>.<M>.
```

No other `## Stopped — …` section is legal. In particular:

- Build / test failure is not a stop. The loop owns getting back
  to green; describe the failure under `Active task` with the
  diagnosis attempted, not under a stop heading.
- ADR-level design choices are not a stop. They are handled
  inline per CLAUDE.md; the AI drafts and accepts the ADR itself.
  Handover entries that frame an ADR-level choice as a stop are a
  block-level finding — rewrite as an Active task entry that
  names the design choice and the candidate ADR slug.
- Smell-driven interruption is not a stop. The surgery already
  landed at the interrupt; the handover does not record it as a
  stop event.

## Resume must not propagate a stale stop

When a fresh session reads handover and sees an existing
`## Stopped — user requested` section, that section is **history
of the previous session's end**, not a directive for the current
session. Step 1 of `/continue` deletes the section as part of the
resume rewrite (the user's directive applied to the previous
session only — see CLAUDE.md § The only stop). The current
session resumes the loop unchanged.

## Stale-ness

This rule is stale if:

- The forbidden-phrase table no longer matches actual handover
  drift. Re-derive from
  `git log -p .dev/handover.md --since="90 days ago"` and surface
  new euphemisms.
- CLAUDE.md § The only stop changes; the "Legitimate stop
  framing" section above must mirror the canonical wording.

## Related

- [`no_handover_predictions.md`](no_handover_predictions.md) —
  forbids numeric / behaviour predictions (sibling rule).
- CLAUDE.md § The only stop — the single-condition stop
  this rule references.
- `~/Documents/MyProducts/zwasm_from_scratch/.claude/rules/handover_framing.md`
  — the v2 source rule cw adapted from.
