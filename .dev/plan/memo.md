# ClojureWasm Development Memo

## Current State

- Phase: 12 (Zig Foundation Completion + SCI Test Port)
- Roadmap: .dev/plan/roadmap.md
- Current task: T12.8 — gensym, compare-and-set!, format
- Task file: (none — create on start)
- Last completed: T12.7 — Namespace ops II: ns-map, ns-publics, ns-interns
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T12.7 completed — Namespace ops II

Added 3 builtins to `src/common/builtin/ns_ops.zig`:

- `ns-interns`: Returns map of interned Vars (Namespace.mappings)
- `ns-publics`: Same as ns-interns (no private vars yet)
- `ns-map`: Returns map of all mappings (interned + referred)
- Helper: `resolveNs()` for symbol->Namespace resolution
- Helper: `varMapToValue()` for VarMap->{symbol->var_ref} conversion
- Registry: 149 builtins, 264/702 vars done

### T12.8 scope

Misc Tier 1 utilities: gensym, compare-and-set!, format

- `gensym` — generate unique symbol (needs global counter)
- `compare-and-set!` — CAS on atom (needs Atom access)
- `format` — string formatting (Clojure's java.lang.String/format equivalent)

### Deferred items to watch

- **F24**: Before T12.9 (SCI triage), refine vars.yaml status values
  to include `stub` and `defer`. See SS10 (549-564).
- **F22**: T12.9 introduces compat_test.yaml for test tracking. See SS10 (495-509).

### Builtin Count

149 builtins registered
264/702 vars done
