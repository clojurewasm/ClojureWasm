---
paths:
  - "**"
---

# Plan revision thinking (hook)

> SSOT: `.dev/principle.md`. This file is the trigger only.

## Bad Smell sensor

If "wait, this feels off" / "this seems different from what we
planned" / "I'll fix it later" / "this looks like a hassle, let me
take a side route" comes to mind while editing, interrupt the
current edit, re-read `.dev/principle.md`, and take the surgery
at the right depth before continuing. The interrupt is not a
session stop — the loop keeps running, the smell just lands its
fix in-flight.

## Judgement is yours

- The catalogue is a memory aid, not a checklist.
- Pick depth 1-4 yourself.
- Fork a subagent for a deeper look when warranted.
- Record the conclusion at the right layer (commit message / ADR /
  `debt.md` / `private/notes/`).

## Why this rule auto-loads everywhere

The smell can appear anywhere — in a `.zig` source change, in an
ADR edit, in a ROADMAP amendment, in a rule rewrite. Path `**` is
intentional. The detail is in the SSOT; the hook is short so it
does not crowd the context.
