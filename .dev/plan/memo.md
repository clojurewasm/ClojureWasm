# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.2 — Var as Value variant + Var metadata support
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.1 Completed

Metadata system implemented: meta, with-meta, vary-meta (core.clj),
alter-meta!, reset-meta!. All work on collections, fn_val, and atoms.

**Deferred**: alter-meta!/reset-meta! on Vars — Var is not a Value variant.
T11.2 addresses this by adding Var to the Value union.

### T11.2 Considerations

Var needs to be a Value variant so that `#'some-var` can return a Var
as a first-class value. This enables:

- `(meta #'some-var)` to return Var metadata as a map
- `(alter-meta! #'some-var f args)` to mutate Var metadata
- Var as first-class value (pass to functions, store in collections)

Current Var fields (doc, arglists, added, etc.) should be exposed
via `(meta #'var)` as a standard Clojure metadata map.

### Builtin Count

110 builtins registered (was 106, +4: meta, with-meta, alter-meta!, reset-meta!)
216/702 vars implemented (was 211, +5 including vary-meta in core.clj)
