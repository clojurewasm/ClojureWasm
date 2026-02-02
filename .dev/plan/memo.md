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

### T11.2 Background

Var needs to become a Value variant so that `(var foo)` returns a Var value,
and `alter-meta!` / `reset-meta!` can work on Vars directly.

Current state:

- Value tagged union has no Var variant
- `var` special form exists in Reader (var_quote -> `(var x)`)
- Analyzer handles `var` special form but result is used for resolution only
- alter-meta! and reset-meta! (T11.1) work on collections/symbols/fns but NOT on Vars

What T11.2 needs:

- Add `.var_ref` (or `.var`) variant to Value tagged union
- `(var foo)` should evaluate to the Var value itself
- var?, var-get, var-set builtins
- alter-meta!, reset-meta! extended to work on Var values
- Metadata on Vars: docstring, arglists, etc. accessible via `(meta #'foo)`

### Important: comptime switch exhaustiveness check

Include a comptime test verifying no `else => {}` exists in critical Value switch
statements (SS3: fixup verification institutionalization). This prevents silent
breakage when new Value variants are added.

### Builtin Count

110 builtins registered (was 106, +4: meta, with-meta, alter-meta!, reset-meta!)
216/702 vars implemented (was 211, +5 including vary-meta in core.clj)
