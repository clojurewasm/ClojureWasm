# ClojureWasm Development Memo

## Current State

- Phase: 10 (VM Correctness + VM-CoreClj Interop)
- Roadmap: .dev/plan/roadmap.md
- Current task: **T10.1 — Fix VM loop/recur wrong results (F17)**
- Task file: (none — create on start)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T10.1 Investigation Notes

**Symptoms** (from T9.5.4 VM benchmark):

- fib_loop: returns 25 instead of 75025 (n=25, 3 loop bindings: i, a, b)
- arith_loop: returns 1000000 instead of 499999500000 (n=1000000, 2 bindings: i, sum)

**Pattern**: Both return the value of the FIRST loop binding (i) at completion,
instead of the correct binding (a for fib, sum for arith). This suggests:

- After recur + jump_back, the stack is in correct state for the LOOP
- But when the loop EXITS (if branch falls through), the body result
  is being read from the wrong stack slot

**Key code locations**:

- VM recur opcode: `src/native/vm/vm.zig:265` — pops args, writes to slots, resets sp
- Compiler emitLoop: `src/common/bytecode/compiler.zig:203` — emits pop instructions after body
- Compiler emitRecur: `src/common/bytecode/compiler.zig:244` — emits recur + jump_back

**Hypothesis**: The `emitLoop` cleanup code (`pop` N times after body) may be
interacting with the recur sp reset, causing the loop exit path to pick up
the wrong value. Specifically, when the loop body evaluates to the `if` result
and the `if` takes the else branch (returning a binding), the value on top of
stack after all the pops may be wrong.

Look at how `emitLoop` handles cleanup vs how `emitLet` does it (pop_under vs pop).
emitLet uses `pop_under` to keep body result; emitLoop uses plain `pop` N times.
