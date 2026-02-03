# ClojureWasm Development Memo

## Current State

- Phase: 13 (SCI Fix-ups + clojure.string + Core Expansion)
- Roadmap: .dev/plan/roadmap.md
- Current task: T13.1 — list?, int?, reduce/2, set-as-fn, deref-delay
- Task file: (none — create on start)
- Last completed: T12.9 — SCI test port + triage
- Blockers: none
- Next: T13.1

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### Phase 13 — SCI Fix-ups + clojure.string + Core Expansion

**Goal**: Fix remaining SCI test failures (4 skipped, 15 skipped assertions),
add clojure.string namespace, and expand core.clj. Target: 74/74 SCI tests pass.

### T13.1 — Missing Zig Builtins (SCI fix-ups)

Items to implement:

1. **list?** — predicate, crashes on call (macroexpand-detail-test skip)
   - Add to predicates.zig, register in registry
   - Check: `.list` variant in Value

2. **int?** — predicate, not implemented (basic-predicates-test, type-predicates-test)
   - Alias for `integer?` or separate implementation
   - Clojure: `int?` checks for fixed-precision integer

3. **reduce/2** — 2-arity reduce without init value
   - Current: `(defn reduce [f init coll] ...)` — 3 args only
   - Need: `(reduce f coll)` — uses `(first coll)` as init, `(rest coll)` as coll
   - Update core.clj with multi-arity

4. **set-as-function** — `(#{:a :b} :a)` → `:a`
   - Sets should implement IFn (lookup)
   - In tree_walk.zig callValue, handle set type

5. **deref on delay** — `@(delay expr)` should work
   - Currently `deref` handles atoms only
   - Need to detect delay maps and call `force`
   - Or implement Delay as proper Value variant

### Registry count: 152 builtins, 267/702 vars done

### Files to modify (T13.1)

- `src/common/builtin/predicates.zig` — add list?, int?
- `src/common/builtin/registry.zig` — register new builtins
- `src/clj/core.clj` — update reduce to multi-arity
- `src/native/evaluator/tree_walk.zig` — set-as-function in callValue
- `src/common/builtin/collections.zig` — deref delay handling (or deref.zig)

### Deferred items to watch

- **F24**: vars.yaml status refinement — deferred until stub functions appear
- **F13/F14**: VM opcodes for defmulti/defmethod/lazy-seq — when VM-only mode needed
