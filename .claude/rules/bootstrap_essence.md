---
paths:
  - "src/**/*.zig"
  - "src/**/*.clj"
  - "src/lang/bootstrap.zig"
  - "src/eval/analyzer/**/*.zig"
  - "src/eval/backend/**/*.zig"
---

# Bootstrap essence

> Folded into [`provisional_marker.md`](provisional_marker.md) §
> "Why this rule exists" at Wave 16 W16-6 (2026-05-26). This file
> remains as a path-frontmatter pointer so editors of bootstrap-
> related Zig + `.clj` files keep auto-loading the chicken-and-egg
> motivation that the original 2026-05-26 W16 introduction
> recorded.

## The pattern, in one sentence

Language implementations grow in **layers**, and an upper layer
cannot be expressed in its finished form until the layer
underneath is reachable. While the underneath is incomplete, the
upper layer **rides provisional behaviour** in whatever already
runs.

## Historical anchors (themes only)

- **Lisp 1962** (Hart & Levin, MIT): first self-hosting compiler
  — write the new compiler in Lisp, test it inside an existing
  Lisp Interpreter, iterate until self-hosting.
- **ClojureScript bootstrap**: ships a pre-built analyzer cache
  for `cljs.core` so the self-host environment starts with "core
  was already loaded".
- **Crafting Interpreters** (Nystrom): spent weeks hand-drawing
  the dependency graph between chapters so each chapter's feature
  could be authored using only what earlier chapters taught.
- **Onramp self-bootstrapping C compiler**: implementation split
  into stages, each stage compilable by the stages before it.

## cw v1 mapping

- Layer 0 — host code (Zig).
- Layer 1 — `rt/` primitives (Zig leaves).
- Layer 2 — Pattern A `.clj` defns composing Layer 1.
- Layer 3 — `(ns ...)` macro / `require` / full namespace
  semantics (lands at ADR-0035 / Phase 6.16.b-4).

Each upper layer ships provisional behaviour against the next
layer's not-yet-existence. The lifecycle is mechanised via
[`provisional_marker.md`](provisional_marker.md) +
`feature_deps.yaml` + `.dev/debt.yaml`.

## What this rule deliberately does *not* prescribe

Specific strategies for each chicken-and-egg — recipe-by-recipe
playbook of how cw v1 should bootstrap each feature. The
historical anchors are pointers to read when relevant, not
templates to copy. The cw v1 judgement space is the project's
most valuable resource; over-prescription would erode it.
