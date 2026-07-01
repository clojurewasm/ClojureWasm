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
  in `data/compat_tiers.yaml`.

## How to apply

- New primitive: spec line is expected before merging.
- Modified primitive: spec line is updated alongside.

## Enforcement

**Reviewer-checked convention — no hard gate** (like `module_docstring.md`;
per `framework_completion.md`, a discipline without a backing script must say
so honestly). Discovery recipe to find primitives missing the spec line:

```sh
# public primitives (pub fn prim*/special*) whose preceding doc block lacks a
# `/// Spec:` line — candidates for a spec citation.
rg -n 'pub fn (prim|special)\w+' src/lang/primitive src/eval \
  | while IFS=: read -r f l _; do
      sed -n "$((l>6?l-6:1)),${l}p" "$f" | grep -q '/// Spec:' || echo "$f:$l"
    done
```

A future `scripts/check_spec_citation.sh` could gate this (D-547); until then it
is a review-time check, not a blocking hook.
