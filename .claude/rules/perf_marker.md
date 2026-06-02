---
paths:
  - "src/**/*.zig"
  - "src/**/*.clj"
---

# PERF marker comments

Auto-loaded when editing source. Codifies the **discoverability** layer
for performance optimizations — code shaped for speed rather than for
the simplest correct form. Sibling to
[`provisional_marker.md`](provisional_marker.md); the SSOT is
[`.dev/optimizations.md`](../../.dev/optimizations.md).

## Why this rule exists

The user's directive (2026-05-31): *"将来の最適化のとき、「最適化して
るんだよ」と分かりやすく — 理想は SSOT 的な箇所があること"*. Optimizations
hide intent: a fast-path `switch` arm or a precomputed field reads like
ordinary code, so a later editor cannot tell "this complexity is here
for speed; the naive form over there is the real contract." Without a
marker, an optimization rots into unexplained complexity, and a bug in
the fast path silently diverges from the naive path (the kind of
divergence F-011's behavioural-equivalence target forbids).

The marker makes every optimization **grep-discoverable**
(`rg 'PERF:' src/`) and the `.dev/optimizations.md` ledger records the
naive↔optimized pair so the equivalence is auditable.

## Canonical form

```zig
// PERF: <one-line what + why faster> [refs: O-NNN, D-NNN?]
```

```clojure
;; PERF: <one-line what + why faster> [refs: O-NNN, D-NNN?]
```

Rules:

- **Single line**, placed directly above the optimized code.
- **`refs:` lists at least one `O-NNN`** (the `.dev/optimizations.md`
  ledger row). Cross-ref the driving `D-NNN` perf-debt row when one
  exists.
- The ledger row carries the detail (naive form / optimized form / why /
  verification); the marker is just the in-code anchor.
- **Removed on revert**, not commented-out (grep-discoverability is the
  point). Flip the ledger row to `RETIRED` in the same commit.

## When it applies

A `PERF:` marker is for code where a **simpler correct form exists** and
was traded for speed:

- A fast-path `switch` arm that special-cases a type for O(1) instead of
  the generic O(n) walk (e.g. `count` of a `.range`).
- A precomputed / cached field that duplicates derivable state.
- A tight-loop reimplementation that bypasses the general dispatch path.
- A representation chosen for iteration speed over the obvious one.

It does **not** apply to code that is simply the natural implementation
(no simpler-but-slower alternative was passed over). Over-marking is
noise; mark only genuine speed-for-simplicity trades.

## Distinguishing PERF from PROVISIONAL

- **`PERF:`** — permanent (or long-lived) optimization; the naive form
  is the *fallback contract*, the marked code is the *fast path*. Lives
  in `.dev/optimizations.md`.
- **`PROVISIONAL:`** — temporary intermediate behaviour pending an
  upstream feature; closes out when that feature lands. Lives in
  `feature_deps.yaml` + `.dev/debt.yaml`.

A single site can be both (a provisional optimization) — carry both
markers, each with its own refs.

## Enforcement

Lightweight by design (the user noted optimizations are too varied for
full mechanical management). No hard gate today. `audit_scaffolding`
may, at a Phase boundary, cross-check `rg 'PERF:' src/` against
`.dev/optimizations.md` rows for orphans in either direction. The
primary value is the grep-discoverable marker + the SSOT ledger, not a
blocking check.
