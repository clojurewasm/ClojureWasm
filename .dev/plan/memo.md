# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.4 — if-some, when-some, vswap!
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.3 completed — major bug fixes included

T11.3 (memoize, trampoline) required fixing several pre-existing bugs:

1. **Bug 1 (compiler stack_depth)**: Fixed in refactoring commit. Compiler
   now tracks actual VM stack position via `stack_depth` field.
2. **Bug 2 (fn-level recur)**: Fixed in both VM (compileArity loop context)
   and TreeWalk (callClosure while-loop for recur_pending).
3. **apply fn_val dispatch**: apply builtin now handles closures via
   bootstrap.callFnVal (was only handling builtin_fn).
4. **VM use-after-free**: bytecodeCallBridge no longer deinits VM (closures
   returned must outlive bridge scope). evalStringVM detaches VM-created
   Fn objects into retained list.

### Builtin Count

113 builtins registered (was 110, +3: var?, var-get, var-set)
221/702 vars implemented (was 219, +2: memoize, trampoline)
