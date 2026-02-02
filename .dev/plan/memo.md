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

### T11.3 — BLOCKED by 2 VM bugs

T11.3 (memoize, trampoline) requires fixing 2 pre-existing VM bugs first.
Full investigation notes in `.dev/plan/active/task_0094_memoize_trampoline.md`.

**Bug 1 (compiler slot mismatch)**: `addLocal` in compiler.zig uses
`locals.items.len` as slot, but when temporaries are on the stack
(e.g. call args), this doesn't match the actual VM stack position.
Affects any `(f (let/loop ...))` pattern. Pre-existing bug, not
introduced by T11.3 work. Fix: add `stack_depth` tracking to Compiler.
Use helper methods (`compileExpr`, `emitPop`, etc.) to centralize tracking.
Key files: `src/common/bytecode/compiler.zig` (addLocal, emitLet, emitLoop).

**Bug 2 (fn-level recur)**: `(fn [n] (if (> n 0) (recur (dec n)) n))`
doesn't work — recur inside fn body (not loop) is unimplemented.
TreeWalk fix: wrap callClosure body exec in while-loop checking recur_pending.
VM fix: set loop_start/loop_locals_base in compileArity after adding params.
Key files: `src/native/evaluator/tree_walk.zig` (callClosure),
`src/common/bytecode/compiler.zig` (compileArity).

**Order**: Fix Bug 1 first, then Bug 2, then implement trampoline + memoize.

### Builtin Count

113 builtins registered (was 110, +3: var?, var-get, var-set)
219/702 vars implemented (was 216, +3)
