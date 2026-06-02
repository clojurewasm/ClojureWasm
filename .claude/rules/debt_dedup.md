---
paths:
  - .dev/debt.yaml
---

# Debt deduplication discipline

> `.dev/debt.yaml` is a structured YAML SSOT (ADR-0072 migration): two
> top-level lists, `active:` and `discharged:`, each entry a mapping
> (`id` / `status` / `category` / `barrier` / optional `quality_floor` /
> `last_reviewed`; discharged entries carry `discharged_at` / `resolution`).
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
4. Otherwise append a new entry under `active:` with the next ID
   (highest existing: `grep -oE 'D-[0-9]+' .dev/debt.yaml | sort -t- -k2 -n | tail -1`).
