# Task 3.16: Import SCI Tier 1 tests

## Goal

Import a subset of SCI compatibility tests from ClojureWasmBeta to validate
the ClojureWasm evaluation pipeline. Tests verify correctness of core
language features: do, if/when, and/or, let, fn, def, loop/recur, etc.

## Approach

Instead of porting the full deftest/is framework, add evalString-based
tests in bootstrap.zig that verify the same expressions from
Beta's test/compat/sci/core_test.clj.

Focus on tests that use currently-implemented features:

- Arithmetic, comparison, logic
- do, if, when, let, fn, def, loop/recur
- Collections: list, vector, map, set
- Higher-order functions: map, filter, reduce
- Macros: cond, ->, ->>
- Atoms: atom, deref, swap!, reset!

Skip tests requiring unimplemented features:

- zero?, pos?, neg?, even?, odd? (not yet as builtins)
- hash-map, hash-set literals in test context
- deftest/is framework
- try/catch/throw (partial)
- for, doseq, loop with destructuring

## Plan

### Step 1: Add missing predicates

Add zero?, pos?, neg?, even?, odd? as builtins (needed by many SCI tests).

### Step 2: Add SCI-style tests as Zig tests

Add evalString-based test cases in bootstrap.zig covering core_test.clj
expressions: do, if/when, and/or, let/fn, loop/recur, etc.

### Step 3: Verify all tests pass

Run zig build test, fix any issues.

## Log

- Added numeric predicates: zero?, pos?, neg?, even?, odd? (predicates.zig)
- Added inc, dec to core.clj
- Fixed callBuiltin variadic support: (+), (- x), (+ x y z), (< 1 2 3) etc.
- Fixed quote for collections: analyzeQuote now uses macro.formToValue (was nil placeholder)
- Added 17 SCI Tier 1 tests covering: do, if/when, and/or, fn, def, defn, let,
  closure, arithmetic, comparisons, sequences, string ops, loop/recur, cond,
  comment, threading macros, quoting, defn-
- All 487 tests pass
