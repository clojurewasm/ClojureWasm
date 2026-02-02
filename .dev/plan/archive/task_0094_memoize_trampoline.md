# T11.3: memoize, trampoline

## Context

Function combinators deferred from Phase 6.9. Both are pure Clojure
definitions in core.clj — no Zig builtins needed.

## Prerequisites (all implemented)

- atom, deref, swap!, reset! (T3.9)
- apply (builtin)
- contains?, get, assoc (collection ops)
- fn? (type predicate)
- if-let (core.clj macro)

## Plan

### 1. memoize

Use `contains?` + `get` (since `find` is not implemented):

```clojure
(defn memoize [f]
  (let [mem (atom {})]
    (fn [& args]
      (if (contains? @mem args)
        (get @mem args)
        (let [ret (apply f args)]
          (swap! mem assoc args ret)
          ret)))))
```

### 2. trampoline

Use `loop` (not fn-level recur — see bugs below):

```clojure
(defn trampoline
  ([f]
   (loop [ret (f)]
     (if (fn? ret)
       (recur (ret))
       ret)))
  ([f & args]
   (trampoline (fn [] (apply f args)))))
```

### 3. Tests

Test via CLI with .clj files.

## Blocking Bugs Found

### Bug 1: VM compiler locals vs stack position mismatch

**Symptom**: `(println (loop [n 3] (if (> n 0) (recur (dec n)) n)))` fails
with TypeError in VM. Works fine in TreeWalk.

**Root cause**: Compiler's `addLocal` assigns `slot = self.locals.items.len`
which counts only named locals, not unnamed temporaries on the stack.
When a let/loop binding is inside a call expression, the call arguments
(e.g. `println`'s var_load result) are on the stack but not in `locals`,
so `local_load slot=0` points to the wrong stack position.

**Bytecode evidence** (from dump):

```
0: var_load    #0  ; println    ← stack[0] = println
1: const_load  #1  ; 3          ← stack[1] = 3, addLocal "n" → slot=0
2: local_load  slot=0           ← reads stack[frame.base+0] = println (WRONG!)
```

**Key insight**: This bug exists in both fn bodies AND top-level code.
Wrapping top-level code in an implicit fn (方式B) does NOT fix it
because the same misalignment occurs inside fn bodies when temporaries
are on the stack (e.g. `(fn [] (println (loop ...)))`).

**Correct fix**: Add `stack_depth` tracking to the Compiler so that
`addLocal` uses actual stack position, not locals count. This requires
updating each emit method to track stack effects (+1 for push, -1 for
pop/binary-op, etc.).

**Design note**: Standard approach in stack-based compilers. For clean
implementation, centralize tracking in helpers (`compileExpr()` that
calls `compile()` + increments depth, `emitPop()`, `emitBinaryOp()`)
rather than sprinkling `stack_depth +=` across every emit method.

**Scope**: This is a pre-existing VM bug (confirmed by testing on the
commit BEFORE any changes). It affects any expression where let/loop
bindings are nested inside call arguments. All existing tests pass
because they only test simple top-level expressions where locals and
stack positions happen to align.

### Bug 2: fn-level recur not implemented

**Symptom**: `((fn [n] (if (> n 0) (recur (dec n)) n)) 3)` returns nil
(TreeWalk) or wrong result (VM) instead of 0.

**Root cause (TreeWalk)**: `callClosure` executes `self.run(arity.body)`
once and returns, ignoring `recur_pending`. Only `runLoop` checks
`recur_pending`.

**Fix (TreeWalk, verified working)**: Wrap body execution in a
`while (true)` loop that checks `recur_pending` after each execution
and rebinds params from `recur_args` before re-running the body.
The fix was tested and confirmed correct before being reverted.

**Root cause (VM)**: `compileArity` creates a fresh `fn_compiler` with
`loop_start = null`, so `emitRecur` generates no `jump_back` instruction.

**Fix (VM)**: After adding params as locals in `compileArity`, set
`fn_compiler.loop_locals_base`, `loop_start`, and `loop_binding_count`
so that recur in fn body jumps back to the body start.

**Note**: The VM fix depends on Bug 1 being fixed first, because
fn-level recur uses `loop_locals_base` which needs correct stack
positions.

## Recommended Approach for Next Session

1. Fix Bug 1 first (compiler stack_depth tracking)
2. Fix Bug 2 (fn-level recur in both TreeWalk + VM)
3. Then implement trampoline + memoize in core.clj
4. Record decisions in decisions.md

## Log

### Session 2026-02-03

- Investigated trampoline/memoize prerequisites — all met
- Discovered Bug 2 (fn-level recur) while testing trampoline
- TreeWalk fix for Bug 2 verified working (reverted)
- Discovered Bug 1 (compiler slot mismatch) while testing VM
- Bug 1 is pre-existing, not introduced by any changes
- Attempted 方式B (implicit fn wrapper) — does NOT work because
  the bug occurs inside fn bodies too, not just at top-level
- Attempted 方式A (stack_depth tracking in compiler) — correct approach
  but implementation was incomplete when session ended
- All changes reverted to clean state
