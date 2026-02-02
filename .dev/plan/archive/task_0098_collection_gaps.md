# T12.1: Collection gaps: dissoc, disj, find, peek, pop, empty

## Overview

Add 6 fundamental collection builtins to collections.zig.
These are prerequisites for many Tier 2 core.clj functions.

## Plan

### Step 1: dissoc — remove key from map

- `(dissoc map key)` and `(dissoc map k1 k2 ...)`
- Returns new map without the specified key(s)
- Non-map input: TypeError

### Step 2: disj — remove value from set

- `(disj set val)` and `(disj set v1 v2 ...)`
- Returns new set without the specified value(s)
- Non-set input: TypeError

### Step 3: find — lookup MapEntry in map

- `(find map key)` => [key value] or nil
- Returns 2-element vector (MapEntry) or nil

### Step 4: peek — stack top

- `(peek vector)` => last element
- `(peek list)` => first element
- `(peek nil)` => nil

### Step 5: pop — stack pop

- `(pop vector)` => vector without last
- `(pop list)` => list without first
- `(pop nil)` => error (unlike peek)

### Step 6: empty — empty collection of same type

- `(empty [1 2])` => []
- `(empty '(1 2))` => ()
- `(empty {:a 1})` => {}
- `(empty #{1})` => #{}
- `(empty nil)` => nil
- `(empty "abc")` => nil (Clojure behavior)

### Step 7: Register + compare-mode tests + E2E

## Log

- Added 6 builtins to collections.zig: dissocFn, disjFn, findFn, peekFn, popFn, emptyFn
- Registered in builtins table (25 → 31 entries)
- Registry total: 120 → 126 builtins
- 20 unit tests added (dissoc: 3, disj: 2, find: 2, peek: 4, pop: 4, empty: 3, builtins count: 2)
- 4 compare-mode tests added to eval_engine.zig (dissoc, find, peek, empty)
- E2E verified: VM and TreeWalk produce identical output
- vars.yaml: 6 vars marked done (231 → 237)
- All tests pass
