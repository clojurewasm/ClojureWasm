---
paths:
  - "**"
---

# Extended challenge before a user stop

## Rule

The loop never stops on its own (CLAUDE.md § The only stop). The
only moment this rule fires is when the **user has just asked the
loop to stop** and the per-task note is being written to close
the session.

In that note, record 3 short items so the next session resumes
without spinning up cost:

1. **Alt hypothesis**: an alternative approach not taken
   (3-5 sentences).
2. **Next experiment**: a concrete next experiment with an
   executable command.
3. **Explicit blocker**: what currently blocks the next experiment
   (technical / decision / external) — or "none" if the next
   experiment is ready to run.

## Why

- Prevents the next session from re-deriving context.
- Surfaces alternatives that the smell sensor flagged but did not
  surgery — they become the next session's first considered moves.
- Keeps the handover-to-resume bridge concrete, not narrative.

## How to apply

When the user issues a stop directive, record the 3 items as the
last section of `private/notes/<phase>-<task>.md` (the per-task
note for the in-flight task). Then write the
`## Stopped — user requested` section in handover per
`handover_framing.md` and push.

Do **not** trigger this rule on task / region / cluster / commit
boundaries. Those roll into the next unit of work; no stop, no
provisioning needed.
