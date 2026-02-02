# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.1 — meta, with-meta, vary-meta, alter-meta!
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 11 Focus

Metadata system is prerequisite for many Clojure idioms. T11.1 adds the
core metadata builtins: meta, with-meta, vary-meta, alter-meta!

### Metadata Design Considerations

- Value types that support metadata: PersistentList, PersistentVector,
  PersistentArrayMap, PersistentHashSet, Symbol, Var, Fn
- Metadata is a map (PersistentArrayMap typically)
- with-meta returns a new value with metadata attached (immutable)
- vary-meta applies a function to the existing metadata
- alter-meta! mutates metadata on Vars/atoms (mutable reference types)
- meta returns the metadata map (or nil)

### Implementation Approach

- Add an optional metadata field to Value types that support it
- For immutable types (collections, symbols): store metadata as part of the value
- For mutable types (Var, Atom): metadata is already conceptually part of their state
- Zig approach: metadata can be a ?\*PersistentArrayMap or ?Value on relevant types

### VM Performance Profile (from Phase 10)

VM is 4-9x faster for pure computation but slower for HOF-heavy workloads
due to cross-backend dispatch (VM -> TW -> VM). AOT pipeline (F7) would
eliminate this overhead but is a larger project for a future phase.
