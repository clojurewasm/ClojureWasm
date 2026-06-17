---
paths:
  - .dev/debt.yaml
---

# Debt deduplication discipline

> `.dev/debt.yaml` is a structured YAML SSOT (ADR-0072 migration; 3 sections
> since the 2026-06-15 ledger audit): `active:` (actionable, drained
> easiest-first), `standing:` (epics/campaigns/capstones + the indefinitely-
> deferred future bucket — the loop does NOT auto-drain these), and
> `discharged:` (resolved/history). Each entry a mapping
> (`id` / `status` / `category` / `barrier` / optional `quality_floor` /
> `last_reviewed`; discharged is MIXED-schema — ~199 reuse the `status:
> DISCHARGED …` active shape, ~155 use the lighter `discharged_at` /
> `resolution`, so a row moved from active keeps its `status` block as-is).
> Recipes (next-id/dup/phantom) span all 3 sections — parenthesize any
> `(.active[],.standing[],.discharged[]) | select(…)` union (the `|`-binds-
> tighter-than-`,` footgun; see [`yaml_ssot_yq.md`](yaml_ssot_yq.md)).
> Edit it as YAML — there is no Markdown table to align any more.
>
> **Querying it from a shell** (counts, filters, is-discharged, next-id, the
> `env(VAR)` escaping idiom): see [`yaml_ssot_yq.md`](yaml_ssot_yq.md) — the
> `yq` cookbook, so the shell-escaping is not re-derived each time.

## Rule

Before adding a new debt entry, grep for class overlap:

```sh
rg -n '<keyword>' .dev/debt.yaml
```

Many additions are actually re-tagging an existing entry (status / barrier
/ last_reviewed update).

## Why

- Inflated debt count makes per-row predicate audit expensive.
- Duplicate root-cause tracking misleads Phase boundary judgment.

## How to apply

1. Extract keyword from the domain (e.g., "lazy-seq", "boxing",
   "interop", "MVCC").
2. `rg -n '<keyword>' .dev/debt.yaml` to find related entries.
3. Update the existing entry (status / barrier / last_reviewed) if
   relevant.
4. Otherwise append a new entry under `active:` with the next ID. Prefer the
   Edit tool (hand-write `- id: "D-NNN"` quoted) over `yq +=` — a `+=` append
   writes the id UNQUOTED, which the grep recipe undercounts (yaml_ssot_yq.md
   Golden-rule #4). Highest existing id (style-agnostic via yq; MUST scope to
   `.id`, else prose `D-NNN` cross-refs / a typo'd phantom inflate it):
   `yq -r '.active[].id, .standing[].id, .discharged[].id' .dev/debt.yaml | grep -oE '[0-9]+' | sort -n | tail -1`
   (grep fallback must be quote-tolerant: `grep -oE 'id: "?D-[0-9]+'`).
