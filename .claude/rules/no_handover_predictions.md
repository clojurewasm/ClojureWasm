---
paths:
  - .dev/handover.md
---

# No predictions in handover.md

## Rule

Do not write numeric predictions in handover.md.
"~16 fails are expected" produces a stale hypothesis.

## Why

- Predictions diverge from actual measurements as time passes.
- Next session resumes against the prediction rather than current state.
- Live measurement scripts produce the source of truth instead.

## How to apply

- Facts are OK (commit SHA, gate green/red, debt count).
- Predictions are NOT OK ("~5 tasks remain").
- Use concrete identifiers ("task X.Y is next") rather than counts.

## Examples

Don't: "Remaining: ~3 special forms"
Do:    "Remaining: ADR-0007 amendment + task 4.4 Opcode enum"
