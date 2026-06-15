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
   condition (already a `debt.yaml` row by default — handover only
   names the row by ID).

Anything else is forbidden framing. The loop reads handover to
decide **what to do next**, not whether to do anything.

## Resume contract (mandatory top section, 3-5 lines)

Every handover.md MUST start with a tight contract block before
any other section (the cold-start reading list can follow it
but the contract comes first):

```markdown
## Resume contract

- HEAD: <sha or "see git log">
- First commit on resume MUST be: <concrete task — §9.<N>.<M>
  identifier, ADR slug, or file path>
- Forbidden this session: <one-line list — empty is OK>
```

This is the first thing the next session reads. Vague /
multi-option phrasing here is a block-level finding.

- "First commit MUST be" wording is required, not "Recommended".
  Soft phrasing ("consider", "next could be") allows the
  resuming loop to substitute its own first task — that
  defeats the purpose.
- "Forbidden this session" exists to record the previous
  session's surfaced-but-rejected directions ("expand primitive
  cluster" when the real next task is regex impl) so the next
  session does not re-derive the same pivot. Leave empty if
  there is nothing to forbid.

## Hard length limit: ≤ 100 lines

Above 100 lines, the framing has drifted into log / deliberation /
forecast. Trim before commit. `git log` and `.dev/ROADMAP.md`
already carry the history and the forecast.

### The cap is advisory in hook mode (2026-06-15 — the trim-Edit deadlock fix)

The 100-line cap is a **soft quality bound**, so the PreToolUse:Edit
hook (`scripts/check_handover_framing.sh`) treats it as **advisory**:
when `.dev/handover.md` is over cap, hook mode **warns but does NOT
block** the edit. This lets a multi-step trim chain — or any edit that
*reduces* the file toward the cap — land freely via the Edit/Write
tool. (The earlier git-HEAD-based "trim-Edit exemption" did not cover
the common case: when the over-cap state was introduced by the *same
session's* uncommitted edits, HEAD was still ≤ cap so no exemption was
granted, and the only escape was a Bash rewrite bypassing the hook —
the recurring deadlock this fix removes.)

The cap is still **enforced at the audit boundary**: `--check` mode
(`audit_scaffolding` A5b) **fails** any over-cap snapshot. So the
≤ 100 discipline holds — the gate just moves from per-edit to audit.

The **forbidden-phrase / section checks STAY blocking** (exit 2) in
both modes — those (surrender framing etc.) are the load-bearing gate;
only the line cap softened. (Mirrors the `md-table-align` hook →
advisory, 2026-06-11, for the same mid-edit-drift reason.)

## Update frequency cap (≤ 2 / session)

Per session: at most 2 handover updates, except at Phase
boundary where the open-§9.<N+1> commit owns one update
(that one does not count against the 2-cap).

The cap exists because the most common failure mode is
**HEAD-pointer churn**: the resuming loop wants to keep
handover's `HEAD: <sha>` line synchronised with the latest
push, and updates after almost every source commit. That is
log accumulation, just disguised as a single-line edit.

- **HEAD pointer is allowed to go stale.** `git log` is the
  SSOT for current HEAD. handover's HEAD field is a coarse
  pointer — "`HEAD ≈ X` (5 commits behind git)" is fine.
- handover only refreshes when the **Active task identifier
  itself changes** (e.g. §9.6 closed → §9.7 opens, or ADR
  status flipped, or a new Forbidden item surfaced).
- Cosmetic re-wording / count updates / "now there are 48
  primitives not 33" edits are churn — they belong in `git
  log` of the source files, not in handover.

If a session hits the 2-update cap and still wants to
record progress, write to `private/notes/<task>.md`
(gitignored) instead.

## Forbidden patterns (grep-enforceable)

The following appearances anywhere in `.dev/handover.md` are
**block-level findings** that resume Step 1 (`/continue`) must
repair before proceeding.

### Phrase-level (surrender / stop-rationalisation framing)

| Phrase                                                                                              | Why forbidden                                                                                                         | Replace with                                                                                                           |
|-----------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|
| `コンテキスト圧があるため` (and variants)                                                           | Auto-compaction is system-handled; not an agent concern                                                               | Just describe the next task                                                                                            |
| `キリがいい` / `自然な区切り` / `natural break`                                                     | Not a stop condition. The only stop is user explicit request                                                          | Drop entirely                                                                                                          |
| `good stopping point` / `この辺で一旦停止` / `region boundary stop` / `task boundary stop`          | Same — region / cluster / task / commit boundaries all roll into the next unit of work                               | Drop entirely                                                                                                          |
| `Phase boundary reached AND ...`                                                                    | Phase boundary is not a stop. The review chain runs and the loop continues into §9.<N+1>                             | Drop the "AND" clause                                                                                                  |
| `If above ~60%` / `/compact` / `context budget`                                                     | Compact-gate concept removed; `/compact` is not Skill-tool callable                                                   | Drop; auto-compaction is transparent                                                                                   |
| `〜判断待ち` / `user 確認待ち` / `awaiting user confirmation` / `awaiting approval`                 | "Awaiting user" is not a stop state. Push is automatic; ADR-level designs are handled inline                          | Drop; if a real external block, file a `debt.yaml` row with `Status: blocked-by: <named external event>` and name it   |
| `cannot be self-decided` / `human judgement` / `human judgment` / `needs human` / `user touchpoint` | The loop self-decides design choices; "needs human" reframes a self-decidable case as a stop                          | Drop entirely; if the design is genuinely ADR-level, draft + accept the ADR inline per CLAUDE.md and link the ADR slug |
| `this needs human judgement` / `help wanted` / `awaiting human review` / `defer to user`            | Same family — invites a pause for human input that is not a stop condition                                           | Drop entirely                                                                                                          |
| `ADR-level decision` / `ADR-phase mode` (as a stop reason)                                          | ADR-level designs are inline work. Smell-driven ADR drafting is an interrupt, not a stop                              | Rewrite as an Active task entry naming the candidate ADR slug + the F-NNN-compliant shape the AI is taking             |
| `smell-cluster trip` / `smell cluster` / `patterned smell` / `goal drift trip`                      | Smell triggers are interrupts, not stops. No frequency-counter rule exists                                            | Drop entirely; the surgery already landed inline at the interrupt                                                      |
| `physically blocked` / `physical block` (when build / test failures are involved)                   | Build / test failure is not a stop condition either. Diagnose and fix; the loop owns getting back to green            | Drop the "block" framing; describe the failure as the current Active task with the diagnosis attempted                 |
| `stopped — physical block` / `Stopped — physical block`                                           | No such stop condition exists                                                                                         | Rewrite into Active task naming the failing test / build artifact and what to try next                                 |
| `physical block / blocker` as a *non-debt-row* reason in handover                                   | All real external blocks live in `debt.yaml` with a `blocked-by: <event>` Status; handover names the D-NNN by ID only | Move to `debt.yaml`, reference here as `D-NNN`                                                                         |

### Structural (log / forecast / reproduced-content accumulation)

| Pattern                                                          | Why forbidden                                                                                                          | Replace with                                                                                                                             |
|------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------|
| More than **one** `## Just landed` section                       | Log accumulation; `git log` is the SSOT                                                                                | Keep at most the most-recent landing as a single ≤ 10-line section, or drop entirely once next task starts                              |
| `## Future ... shopping list` / forecast tables                  | Forecast belongs in `.dev/debt.yaml` (recall trigger row) or ROADMAP §A / ADR governance                              | Move to debt.yaml as a `D-NNN` row with `Status: recall trigger` and remove from handover                                                |
| `## Notes for the next session` reproducing rule / skill content | CLAUDE.md / `.claude/rules/` / skill `SKILL.md` are the SSOT — auto-loaded each session                               | Drop; the next session re-reads the source SSOT                                                                                          |
| Numeric predictions (`~N tasks remain`, cycle counts)            | Predictions diverge from reality as time passes; the next session resumes against the stale guess instead of measuring | Concrete identifiers (`next: §9.6 / 4.4`); no counts. Live measurement scripts (`git log`, debt.yaml, audit_scaffolding) produce truth. |
| Multi-paragraph editorial framing of work size                   | "deep work" / "substantial multi-cycle" / "重い" framings are stop rationalisations                                    | Just name the task and the entry ADR                                                                                                     |

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
  only; otherwise the row belongs in `.dev/debt.yaml`.

## What handover IS NOT for

- Listing past landings (`git log --oneline` is the SSOT).
- Listing future ADRs / debts / refactors (debt.yaml and ROADMAP
  §A are the SSOTs).
- Re-explaining rules / skills / output styles (the SSOT files are
  auto-loaded each session).
- Multi-option pickup menus — pick the one option in handover
  itself.
- "Cycle 1 did X, cycle 2 did Y" running log (per-task notes in
  `private/notes/` are the SSOT and are gitignored).

## Reviewer checklist

When reviewing a handover.md commit:

- [ ] **Top section is `## Resume contract`** with 3 fields:
      HEAD / First commit MUST be / Forbidden this session.
      "MUST be" wording present (not "Recommended").
- [ ] ≤ 100 lines total.
- [ ] No phrase from the forbidden-phrase table.
- [ ] At most **one** `## Just landed` section.
- [ ] No forecast / shopping-list table.
- [ ] `Active task` names a concrete next §9.<N>.<M> task, not
      an option list.
- [ ] `Open questions / blockers` rows are either testable
      external blockers OR already mirrored as `.dev/debt.yaml`
      D-NNN rows (named here by ID).
- [ ] No numeric predictions — concrete identifiers only.
- [ ] If this is the 3rd+ handover update in the session,
      the change must be Active-task-identifier-level
      (Phase boundary / ADR status flip / new Forbidden);
      HEAD-pointer-only churn is rejected.

## How enforcement runs

Wave 16 (W16-3) lifts the resume-time grep into a PreToolUse:Edit
hook so the gate fires at the moment the edit is written, not at the
next resume's Step 1 scan.

- **Live gate** — `scripts/check_handover_framing.sh` wired into
  `.claude/settings.json` PreToolUse Edit|Write chain. Every edit
  to `.dev/handover.md` runs the script; a forbidden phrase /
  `## Future ... shopping list` / `## Notes for the next session`
  heading / >1 `## Just landed` sections **blocks** the edit (exit 2)
  with the offending lines printed. The **over-cap length is ADVISORY
  in hook mode** (warns, does not block — the trim-Edit deadlock fix,
  2026-06-15; see § "The cap is advisory in hook mode") and **strict
  in `--check`** (audit) mode.
- **Audit-time fallback** — `audit_scaffolding/CHECKS.md` A5b runs
  the same script in `--check` mode at Phase boundary, catching
  drift that may have slipped past the live gate (e.g. if a future
  euphemism is not yet in the regex).
- **Resume-time backstop** — `/continue` Step 1 reads handover; if
  the file violates the rule, the FIRST task on resume is the
  handover rewrite, not the prose-suggested next task.

The canonical forbidden-phrase regex lives in
`scripts/check_handover_framing.sh::FORBIDDEN_PHRASES_RE`. Update
the rule's forbidden-phrase table and the script's regex together
when a new euphemism is identified.

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

- CLAUDE.md § The only stop — the single-condition stop
  this rule references.
- `scripts/check_handover_framing.sh` — the PreToolUse:Edit hook
  that enforces the forbidden-phrase table + length cap (Wave 16
  W16-3); canonical regex lives at the script's
  `FORBIDDEN_PHRASES_RE`.
- `~/Documents/MyProducts/zwasm_from_scratch/.claude/rules/handover_framing.md`
  — the v2 source rule cw adapted from.
