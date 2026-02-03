# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.7 — Namespace ops II: ns-map, ns-publics, ns-interns
- Task file: (none — create on start)
- Last completed: T12.6 — Namespace ops I: all-ns, find-ns, ns-name, create-ns, the-ns
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.6 completed — Namespace ops I

Added 5 builtins in `src/common/builtin/ns_ops.zig`:

- `the-ns`: Validate and return namespace symbol (error if not found)
- `all-ns`: Return list of all namespace name symbols
- `find-ns`: Look up namespace by symbol, return symbol or nil
- `ns-name`: Return namespace name as symbol (identity)
- `create-ns`: Find or create namespace, return symbol
- D47: Namespace represented as symbol, not a new Value variant
- Registry: 146 builtins, 261/702 vars done

### T12.7 scope

Namespace Var mapping: ns-map, ns-publics, ns-interns

- `ns-map` — return map of all mappings (interned + referred) in namespace
- `ns-publics` — return map of public Var mappings
- `ns-interns` — return map of interned Vars (not referred)
- These return maps of {symbol -> var_ref}
- Need to access Namespace.mappings and Namespace.refers
- Same file: `src/common/builtin/ns_ops.zig`

### Deferred items to watch

- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

146 builtins registered
261/702 vars done
