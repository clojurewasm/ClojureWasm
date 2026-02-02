# T11.4: if-some, when-some, vswap!

## Overview

Add nil-safe conditional macros (`if-some`, `when-some`) and volatile
support (`volatile!`, `vreset!`, `volatile?`, `vswap!`).

## Plan

### Step 1: Add Volatile Value variant (value.zig)

- Add `Volatile` struct (identical to Atom: `value: Value, meta: ?*Value = null`)
- Add `volatile: *Volatile` variant to Value tagged union
- Update `formatPrStr`: `#<volatile val>`
- Update `eql`: identity equality (pointer compare)
- Update `typeOf` in tree_walk.zig: return "volatile"

### Step 2: Volatile builtins (atom.zig — extend)

- `volatile!` — create a volatile with initial value
- `vreset!` — set volatile value (non-atomic reset)
- `volatile?` — type predicate
- Extend `deref` to support volatile (return inner value)

### Step 3: Register builtins (registry.zig)

- Add new builtins to atom_mod.builtins array
- Update builtin count test: 113 + 3 = 116

### Step 4: core.clj macros

- `if-some` — like if-let but tests `(not (nil? temp))` instead of truthiness
- `when-some` — like when-let but tests `(not (nil? temp))`
- `vswap!` — macro: `(vreset! vol (f (deref vol) args...))`

### Step 5: Integration tests

- Volatile E2E tests via cljw
- if-some/when-some tests via cljw
- vswap! tests via cljw
- EvalEngine compare tests

### Step 6: Update vars.yaml + checklist

## Log

- Added Volatile struct to value.zig (like Atom but non-atomic)
- Added volatile_ref variant to Value union
- Updated formatPrStr, eql, typeOf, valueToForm for volatile_ref
- Updated main.zig and nrepl.zig writeValue for volatile_ref
- Added volatile!, vreset!, volatile? builtins in atom.zig
- Extended deref to support volatile_ref
- Added if-some, when-some macros to core.clj (nil-safe conditionals)
- Added vswap! macro to core.clj
- All unit tests pass, E2E tests pass on both VM and TreeWalk backends
- Builtin count: 113 → 116, Var count: 221 → 227
