# Task 3.10: Create clj/core.clj bootstrap — defmacro, defn, when, cond, ->, ->>

## Goal

Implement macro expansion in the Analyzer and create a core.clj bootstrap
file defining fundamental macros.

## Dependencies

- T3.9 (atom builtins) — completed
- All Phase 3a tasks — completed

## Background

The Analyzer currently does not reference Env (Phase 1c design). For macro
expansion, the Analyzer needs to:

1. Access Env to check if a called symbol is a macro Var
2. Execute the macro function (Form -> Form transformation)
3. Re-analyze the expanded Form

syntax-quote (`), unquote (~), and unquote-splicing (~@) are already
implemented in the Reader. defmacro analysis produces DefNode(is_macro=true).
TreeWalk and VM both set the macro flag on Var when executing def.

## Plan

### Step 1: Add Env reference to Analyzer

Add optional `env: ?*Env` field to Analyzer. When env is present, the
Analyzer can look up Vars to check for macros.

### Step 2: Macro expansion in analyzeList

When analyzing a list (function call), before treating it as a regular call:

1. Check if callee symbol resolves to a macro Var (via env)
2. If macro: get the function Value from the Var
3. Call the macro function with raw Forms as arguments (converted to Values)
4. Convert the returned Value back to a Form
5. Re-analyze the resulting Form

This requires:

- Form -> Value conversion (for passing forms as args to macro fn)
- Value -> Form conversion (for getting the expanded result back)
- Calling a BuiltinFn or fn_val from within the Analyzer

### Step 3: Form <-> Value conversion utilities

Create conversion functions:

- `formToValue(form: Form) -> Value` — wraps Form data into runtime Values
- `valueToForm(value: Value) -> Form` — unwraps Value back into Form

These enable the macro function to manipulate forms as data.

### Step 4: Macro execution bridge

The Analyzer needs to call macro functions. Options:

- Direct call for builtin_fn (simple)
- TreeWalk mini-evaluator for fn_val (needed for Clojure-defined macros)

For Clojure-defined macros (the whole point of core.clj), we need a
TreeWalk instance that can execute macro functions. The Analyzer will hold
a reference to a TreeWalk evaluator (or create one on demand).

### Step 5: Create src/clj/core.clj

Bootstrap file with:

```clojure
(defmacro defn [name & fdecl]
  `(def ~name (fn ~name ~@fdecl)))

(defmacro when [test & body]
  `(if ~test (do ~@body)))

(defmacro cond [& clauses]
  (when (seq clauses)
    `(if ~(first clauses)
       ~(second clauses)
       (cond ~@(rest (rest clauses))))))

(defmacro -> [x & forms]
  ...)

(defmacro ->> [x & forms]
  ...)
```

### Step 6: Integrate core.clj loading

Add a function to load and evaluate core.clj at startup:

1. Read the file
2. Parse with Reader
3. Analyze each form (defmacro produces DefNodes)
4. Evaluate each form (registers macros in Env)

### Step 7: Tests

- Test macro expansion of each macro
- Test that expanded forms produce correct results
- EvalEngine compare tests

## Complexity Assessment

This is the most complex task in Phase 3. It bridges compile-time (Analyzer)
and runtime (Env/Var), requiring:

- Analyzer <-> Env integration
- Form <-> Value conversion
- Macro function execution during analysis
- Full pipeline: read -> analyze -> compile -> eval for core.clj

Consider splitting into sub-tasks if any step is too large.

## Log

### Step 1: Add Env reference to Analyzer ✅

- Added `env: ?*Env` and `macro_eval_fn` fields to Analyzer struct
- Created `initWithEnv` and `initWithMacroEval` constructors

### Step 2: Form <-> Value conversion (macro.zig) ✅

- Created `src/common/macro.zig` with `formToValue` and `valueToForm`
- Recursive conversion for all Form/Value types
- Roundtrip tests passing

### Step 3: Macro expansion in Analyzer ✅

- Added macro detection in `analyzeList` (between special forms and call)
- `resolveMacroVar`: resolves symbol to Var via env.current_ns
- `expandMacro`: executes macro fn (builtin_fn or fn_val), converts result
  Value back to Form, re-analyzes

### Step 4: Bootstrap evalString pipeline ✅

- Created `src/common/bootstrap.zig` with `evalString` function
- Pipeline: Reader -> Forms -> (per-form: Analyzer -> Node -> TreeWalk)
- `macroEvalBridge` with module-level env for fn_val macro execution
- Tests: constant, function call, multiple forms, def+reference, defmacro

### Step 5: TreeWalk.callValue for macro execution ✅

- Added `callValue` public method on TreeWalk (builtin_fn and fn_val)
- Used by macroEvalBridge to execute fn_val macros

### Step 6: Collection builtins for syntax-quote ✅

- Added `list`, `seq`, `concat` builtins to collections.zig
- Required by Reader's syntax-quote expansion output
- Updated builtins count: 8 -> 11

### Step 7: Variadic rest parameter binding ✅

- Fixed `callClosure` to collect rest args into PersistentList for variadic fns
- Clojure `[name & rest]` now correctly binds rest as a list

### Step 8: fn_name self-recursion binding ✅

- Fixed `callClosure` to bind fn_name in local scope for `(fn name [...] ...)`
- Analyzer allocates local slot for fn_name; callClosure must match

### Step 9: defn macro working end-to-end ✅

- `(defmacro defn [name & fdecl] \`(def ~name (fn ~name ~@fdecl)))`
- Syntax-quote expansion -> macro execution -> re-analysis -> definition
- Test: define defn, use it, call the result — all passing

### Step 10: when macro ✅

- `(defmacro when [test & body] \`(if ~test (do ~@body)))`
- Tests for truthy and falsy paths

### Step 11: core.clj file + loadCore ✅

- Created `src/clj/core.clj` with defn and when macros
- `@embedFile` to embed source at compile time
- `loadCore`: switches to clojure.core ns, evaluates, re-refers to user ns
- Test: loadCore defines macros in clojure.core, usable from user ns

### Summary

All 443 tests passing. Core bootstrap infrastructure complete:

- Macro expansion (Analyzer <-> Env integration)
- Form <-> Value conversion
- evalString pipeline (Reader -> Analyzer -> TreeWalk)
- Variadic parameter binding (rest as list)
- fn_name self-recursion binding
- core.clj embedded loading

Deferred to future tasks:

- D9: cond, ->, ->> macros require loop/let/seq?/next (not yet available)
- D10: loadCore macro_names list is hardcoded (generalize when more macros added)
