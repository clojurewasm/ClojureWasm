# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.5 — re-pattern, re-find, re-matches, re-seq
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.4 completed — volatile + nil-safe conditionals

T11.4 added:

1. **Volatile type**: New Value variant `volatile_ref` with `Volatile` struct.
   Like Atom but non-atomic. Builtins: `volatile!`, `vreset!`, `volatile?`.
   `deref` extended to support volatiles.
2. **if-some/when-some**: core.clj macros — like if-let/when-let but test
   `(nil? temp)` instead of truthiness. `false` passes, `nil` doesn't.
3. **vswap!**: core.clj macro — `(vreset! vol (f (deref vol) args...))`.

### Builtin Count

116 builtins registered (was 113, +3: volatile!, vreset!, volatile?)
227/702 vars implemented (was 221, +6: volatile!, vreset!, volatile?, vswap!, if-some, when-some)
