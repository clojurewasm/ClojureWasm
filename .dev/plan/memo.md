# ClojureWasm Development Memo

## Current State

- Phase: 9.5 complete
- Roadmap: .dev/plan/roadmap.md
- Current task: **Phase planning needed** — no next phase defined in roadmap
- Task file: (none)
- Note: T4.7 (AOT bytecode startup) deferred — needs macro serialization (F7)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Next phase planning priorities

When planning the next phase, consider these in priority order:

1. **VM loop/recur bug** (discovered in T9.5.4 benchmark)
   - fib_loop returns 25 instead of 75025
   - arith_loop returns 1000000 instead of 499999500000
   - Likely a bug in VM recur opcode handling
   - Should be investigated and fixed first (bug > features)

2. **F8: Unified fn_val proto (VM/TreeWalk)** — highest-impact deferred item
   - VM benchmark: 8/11 fail because VM can't call core.clj HOFs
   - Unifying fn_val proto would let VM call TreeWalk closures natively
   - Depends on: understanding current fn_val format differences

3. **Checklist deferred items** — see .dev/checklist.md for full list
   - F7 (macro serialization) blocks AOT pipeline
   - F13/F14 (VM opcodes for defmulti/lazy-seq) blocks VM-only mode

4. **Feature expansion** — more Clojure vars (see vars.yaml todo items)
