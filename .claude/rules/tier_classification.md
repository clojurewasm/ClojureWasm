---
paths:
  - src/lang/**
  - src/runtime/host/**
  - compat_tiers.yaml
---

# Tier classification discipline

## Rule

Every public function and type carries a tier classification A / B / C / D
(per `compat_tiers.yaml` and ADR-0013).

Tier D forms produce a structured error message:

```
Tier D: <reason>, see ADR-NNNN
```

## Why

- Tier classification is the cw v1 contract with users.
- Users see a structured signal for each unsupported feature.
- Tier promotion (e.g., D -> C) requires explicit ADR amendment.

## How to apply

- New function: add entry to `compat_tiers.yaml`, include tier in
  docstring.
- Tier D function: error message format per the rule.
- Tier promotion: amend `compat_tiers.yaml` + ADR.

## Tier promotion / demotion

- D -> any: MAJOR release required (per ROADMAP §1.4 SemVer rule).
- A -> A (no change), A -> B: MAJOR.
- B -> A: MINOR.
- C -> A or C -> B: MINOR.
- A or B -> D: forbidden (would break Clojure source compatibility).
