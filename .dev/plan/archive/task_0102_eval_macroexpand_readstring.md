# T12.5: eval, macroexpand, macroexpand-1, read-string

## Goal

Implement 4 Zig builtins for runtime eval and macro expansion:

- `read-string`: Parse string to Value (reader -> form -> value)
- `eval`: Evaluate a Value form at runtime (value -> form -> analyze -> eval)
- `macroexpand-1`: Single macro expansion step
- `macroexpand`: Repeated expansion until stable

## Plan

### 1. Create `src/common/builtin/eval.zig`

New builtin module with 4 functions:

**read-string** `([s])`:

- Takes a string, creates Reader, reads one form, converts to Value via `macro.formToValue`
- Returns nil for empty string

**eval** `([form])`:

- Takes a Value (data structure), converts to Form via `macro.valueToForm`
- Analyzes the Form via Analyzer (with env)
- Evaluates the Node via TreeWalk
- Needs access to `macro_eval_env` from bootstrap.zig

**macroexpand-1** `([form])`:

- Takes a Value (list form), checks if head is a macro symbol
- If macro: call macro fn once, return expanded Value
- If not macro: return form unchanged

**macroexpand** `([form])`:

- Repeatedly call macroexpand-1 until form stops changing
- Use Value equality (eql) to detect fixpoint

### 2. Register in registry.zig

Add eval_mod import and concatenate builtins.

### 3. Wire bootstrap access

eval and macroexpand need access to `macro_eval_env` (the current Env).
Options:

- Export `macro_eval_env` as pub from bootstrap.zig
- Or use the existing pattern where builtins access env via module-level vars

Decision: Make `macro_eval_env` pub in bootstrap.zig — simplest approach.

### 4. Tests

- read-string: basic types (int, string, vector, map, symbol, keyword)
- eval: `(eval '(+ 1 2))` -> 3
- macroexpand-1: expand defn once
- macroexpand: fully expand a macro

## Log

- Created `src/common/builtin/eval.zig` with 4 builtins:
  - `read-string`: Reader -> Form -> Value pipeline
  - `eval`: Value -> Form -> Analyzer -> TreeWalk eval
  - `macroexpand-1`: Single macro expansion step
  - `macroexpand`: Repeated expansion until stable
- Made `bootstrap.macro_eval_env` pub for eval builtin access
- Registered in `registry.zig` (137 -> 141 builtins)
- Unit tests: 8 read-string tests (int, string, symbol, keyword, vector, map, list, empty)
- Integration tests: 8 tests in bootstrap.zig
- CLI verified: all 4 builtins work end-to-end
- All tests pass (full suite)
