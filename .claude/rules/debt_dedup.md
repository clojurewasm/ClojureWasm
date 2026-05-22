---
paths:
  - .dev/debt.md
---

# Debt deduplication discipline

## Rule

Before adding a new debt row, grep for class overlap:

```sh
rg -n '<keyword>' .dev/debt.md
```

Many additions are actually re-tagging an existing row (status / barrier
/ last reviewed update).

## Why

- Inflated debt count makes per-row predicate audit expensive.
- Duplicate root-cause tracking misleads Phase boundary judgment.

## How to apply

1. Extract keyword from the domain (e.g., "lazy-seq", "boxing",
   "interop", "MVCC").
2. `rg -n '<keyword>' .dev/debt.md` to find related rows.
3. Update the existing row (status / barrier / last reviewed) if
   relevant.
4. Otherwise append new D-NNN (next ID via
   `grep -c "^| D-" .dev/debt.md`).
