---
paths:
  - "src/**/*.zig"
  - "src/**/*.clj"
  - "src/lang/bootstrap.zig"
  - "src/eval/analyzer/**/*.zig"
  - "src/eval/backend/**/*.zig"
---

# Bootstrap essence

Auto-loaded when editing Zig or `.clj` source. A short reminder
that **provisional intermediate states are the default mode of
language-implementation work**, not the exception. Concrete recipes
are intentionally not recorded here — they would over-constrain
the cw v1 judgement space.

## The pattern, in one sentence

Language implementations grow in **layers**, and an upper layer
cannot be expressed in its finished form until the layer
underneath is reachable. While the underneath is incomplete, the
upper layer **rides provisional behaviour** in whatever already
runs.

## Historical anchors (themes only)

- **Lisp 1962** (Hart & Levin, MIT): the first self-hosting
  compiler. Pattern: write the new compiler in Lisp, test it
  inside an existing Lisp Interpreter, iterate until it can
  compile its own source. *Theme: an upper layer can be
  authored before its host fully exists, provided some lower
  host runs.*
- **ClojureScript bootstrap**: ships a pre-built analyzer cache
  for `cljs.core` so the self-host environment starts with
  "core was already loaded" rather than re-deriving it.
  *Theme: a layer's provisional state can be a frozen artefact
  rather than re-evaluated at every start.*
- **Crafting Interpreters** (Nystrom): spent weeks hand-drawing
  the dependency graph between chapters so each chapter's
  feature could be authored using only what earlier chapters
  taught. *Theme: feature ordering is itself a design problem;
  the graph is a first-class artefact.*
- **Onramp self-bootstrapping C compiler**: implementation is
  split into stages, each stage compilable by the stages before
  it. *Theme: chunk the work into self-contained steps that
  cumulate.*

## cw v1 mapping

- Layer 0 — host code (Zig).
- Layer 1 — `rt/` primitives (Zig leaves).
- Layer 2 — Pattern A `.clj` defns composing Layer 1.
- Layer 3 — `(ns ...)` macro / `require` / full namespace
  semantics (lands at ADR-0035 / Phase 6.16.b-4).

Each upper layer ships provisional behaviour against the next
layer's not-yet-existence. The lifecycle is mechanised via
`.claude/rules/provisional_marker.md` + `feature_deps.yaml` +
`.dev/debt.md`.

## What this rule deliberately does *not* say

- "Use strategy X" for any specific chicken-and-egg.
- A recipe-by-recipe playbook of how cw v1 should bootstrap each
  feature.

The cw v1 judgement space is the project's most valuable
resource; over-prescription here would erode it. The historical
anchors are pointers to read when relevant, not templates to
copy.

## Cross-references

- `.claude/rules/provisional_marker.md` — the marker lifecycle
  this essence motivates.
- `.dev/principle.md` — Bad Smell catalogue (the smells that
  emerge when the bootstrap discipline lapses).
- `.dev/project_facts.md` F-002 — finished-form-wins is the
  invariant that keeps the provisional layer from calcifying.
