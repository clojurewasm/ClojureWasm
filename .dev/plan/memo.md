# ClojureWasm Development Memo

## Current State

- Phase: 9.5 (Infrastructure Fixes)
- Roadmap: .dev/plan/roadmap.md
- Current task: T9.5.5 bound? builtin + defonce
- Task file: (none — create on start)
- Last completed: T9.5.3 seq on map (MapEntry)
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T9.5.5: bound? builtin + defonce

- bound? checks if a Var has a root binding
- defonce prevents re-evaluation of def'd form if Var already bound
- Unblocks T9.11 deferred defonce
- bound? needs Var access — check how Var.root works
- defonce is a macro in core.clj: (defmacro defonce [name expr] `(when-not (bound? (var ~name)) (def ~name ~expr)))
