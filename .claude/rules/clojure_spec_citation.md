---
paths:
  - src/eval/**
  - src/lang/**
  - src/runtime/**
  - src/runtime/host/**
---

# Clojure semantics citation

## Rule

Each primitive function and special-form implementation carries a
docstring that cites canonical Clojure semantics.

Format:

```zig
/// Implements clojure.core/conj.
/// Spec: `(conj coll x)` returns coll with x added at the appropriate position
///   - list:    prepend
///   - vector:  append
///   - set/map: add as element/entry
///   - nil:     returns (x) (a one-element list)
/// JVM reference: clojure.core/conj in clojure/core.clj L.115
/// cw v1 tier: A (Phase 3 implemented)
pub fn primConj(rt: *Runtime, ...) !Value { ... }
```

## Why

- Surfaces Clojure spec divergence at code-review time, not at runtime.
- Anchors implementation to a stable reference (JVM Clojure source line)
  rather than tribal memory.
- Tier classification is recorded next to the implementation, not only
  in `compat_tiers.yaml`.

## How to apply

- New primitive: spec line is mandatory before merging.
- Modified primitive: spec line is updated alongside.
- Phase 4 mid: audit primitives without spec line and add them.
