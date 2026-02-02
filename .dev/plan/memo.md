# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.3 — memoize, trampoline
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.3 Background

Implement `memoize` and `trampoline` as core.clj defns.

- memoize: wraps fn with atom-backed cache. Needs: atom, deref, swap!, assoc, get, contains?
  All prerequisites are already implemented.
- trampoline: loop calling fn until non-fn result. Needs: fn? predicate (already exists).

These are Phase 6.9 leftovers (function combinators).

### Builtin Count

113 builtins registered (was 110, +3: var?, var-get, var-set)
219/702 vars implemented (was 216, +3)
