# T11.2: Var as Value Variant + Var Metadata Support

## Goal

Add `var` as a Value variant so `(var foo)` / `#'foo` returns a Var value.
Enable `meta`, `alter-meta!`, `reset-meta!` on Vars. Add var?, var-get, var-set builtins.

## Current State

- Value union has 20 variants, no Var
- Var struct: has doc/arglists/added but NO mutable metadata field
- `var` special form: exists in Reader (var_quote -> (var x)) but NOT in Analyzer special_forms
- alter-meta!/reset-meta!: work on Atom only, not Var
- meta: works on collections, fn_val, symbol — not Var

## Plan

### 1. Add `meta` field to Var struct (var.zig)

Add `meta: ?*PersistentArrayMap = null` to Var.
This holds user-defined metadata (like Clojure's (alter-meta! #'foo assoc :key val)).

### 2. Add `var` variant to Value union (value.zig)

Add `.var_ref: *Var` to Value tagged union.
Update all exhaustive switch statements:

Must update (compile error without):

- value.zig:156 formatPrStr — print as `#'ns/name`
- value.zig:357 eql — pointer identity
- macro.zig:74 valueToForm — convert to (var sym) list
- tree_walk.zig:510 valueTypeKey — return `:var` keyword

### 3. Add `var` special form to Analyzer

Register `var` in special_forms table.
`(var foo)` should resolve the Var and produce a constant node with .var_ref value.

### 4. Implement TreeWalk evaluation of var special form

When evaluating `(var foo)`, resolve the symbol to a Var, return Value{ .var_ref = var_ptr }.

### 5. Extend meta/alter-meta!/reset-meta! to handle Var

- meta: return Var's metadata map
- alter-meta!: apply function to Var's metadata
- reset-meta!: replace Var's metadata

### 6. Add builtins: var?, var-get, var-set, find-var

- var?: check if value is .var_ref
- var-get: deref the var (same as deref but for var values)
- var-set: set root binding (= alter-var-root behavior)
- find-var: lookup var by qualified symbol (returns nil or var)

### 7. comptime switch exhaustiveness test

Add a comptime test that verifies no `else => {}` exists in critical Value switches.

## Log

### Step 1: Add var_ref to Value union + format/eql

- Added `var_ref: *Var` to Value union (21st variant)
- Added Var import to value.zig (circular import works in Zig)
- Updated formatPrStr: prints `#'ns/name`
- Updated eql: pointer identity
- Updated all exhaustive switch statements: macro.zig, predicates.zig (2x),
  tree_walk.zig, nrepl.zig, main.zig

### Step 2: var special form in Analyzer

- Added analyzeVarForm to special_forms table
- Resolves symbol -> Var at analysis time, returns constant node with .var_ref

### Step 3: Var metadata support

- Added `meta: ?*PersistentArrayMap = null` to Var struct
- Extended getMeta() for var_ref
- Extended alter-meta!/reset-meta! for var_ref (with @constCast for *const -> *mut)

### Step 4: Builtins (var?, var-get, var-set)

- var?: checks if value is .var_ref
- var-get: returns var.deref()
- var-set: calls var.bindRoot()
- 113 builtins total (was 110)

### Verified

- All 770 tests pass
- CLI: (var +) -> #'clojure.core/+, (def x 42) #'x -> #'user/x
- CLI: meta/alter-meta!/reset-meta! on Vars work
- CLI: var?/var-get/var-set work
- VM backend: (var x) works (constant load)
