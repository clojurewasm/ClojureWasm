# Task 3.9: Runtime functions — atom, deref, swap!, reset!

## Goal

Add Atom (mutable reference) support to ClojureWasm.

## Dependencies

- T3.5 (BuiltinDef registry) — completed

## Key Semantics

| Function | Signature               | Returns | Description                        |
| -------- | ----------------------- | ------- | ---------------------------------- |
| atom     | (atom val)              | atom    | Creates a new atom with init value |
| deref    | (deref atom)            | val     | Returns current value of atom      |
| reset!   | (reset! atom new-val)   | new-val | Sets atom to new-val               |
| swap!    | (swap! atom f [& args]) | new-val | Applies f to current-val + args    |

## Design Decisions

### Atom as Value variant

Add `.atom` variant to Value union pointing to heap-allocated Atom struct.
Atom struct holds a mutable Value field.

### swap! function call mechanism

swap! needs to call a function Value. Current BuiltinFn signature only receives
allocator + args. Two cases:

- If f is `.builtin_fn`: call it directly via function pointer
- If f is `.fn_val`: **Cannot be called from BuiltinFn** (needs VM/TreeWalk context)

For Phase 3a, implement swap! with builtin_fn support only. Full fn_val support
requires evaluator context (deferred to when higher-order functions are needed).

**Update**: Actually, we don't need to handle fn_val in swap! yet. The common
case at this stage is `(swap! a inc)` where inc is a builtin. User-defined
function support comes with core.clj HOF infrastructure.

### No watchers/validators

Keep Atom minimal. No watches, no validator, no meta. Add later if needed.

## Plan

### Step 1: Add Atom type + Value.atom variant

- Add Atom struct to value.zig
- Add `.atom` variant to Value union
- Update formatPrStr and eql for atom

### Step 2: Create src/common/builtin/atom.zig

- Implement atomFn, derefFn, resetBangFn, swapBangFn
- swap! calls builtin_fn directly, errors on fn_val (for now)

### Step 3: Register in registry.zig

- Add atom module to all_builtins, update count

### Step 4: EvalEngine compare tests

### Step 5: Record design decision in decisions.md

## Log

- Step 1: Added Atom struct + Value.atom variant + formatPrStr/eql support
- Step 2: Created atom.zig with atomFn, derefFn, resetBangFn, swapBangFn (7 tests)
- Step 3: Registered in registry.zig (53 -> 57 builtins)
- Step 4: Added EvalEngine compare tests for atom+deref and reset!
- Step 5: Recorded D8 (swap! builtin-only dispatch) in decisions.md
- All tests green
