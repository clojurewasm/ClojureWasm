---
paths:
  - "**"
---

# Extended challenge before stopping

## Rule

Before stopping, complete 3-step provisioning:

1. **Alt hypothesis**: an alternative approach (3-5 sentences).
2. **Next experiment**: a concrete next experiment with an executable
   command.
3. **Explicit blocker**: what is blocking (technical / decision /
   external).

## Why

- Prevents lazy stop with "investigation cost is high" as defer
  rationale.
- Converts ad-hoc abandonment into a structured ADR-level decision.
- Makes session handover continuous.

## How to apply

Before stop, record the 3 steps in `private/notes/<phase>-<task>.md`.

Omitting the steps inflates resumption cost.
