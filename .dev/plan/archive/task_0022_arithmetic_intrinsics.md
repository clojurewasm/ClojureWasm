# Task 3.1: Arithmetic Intrinsics (+, -, *, /, mod, rem)

## Goal

Make arithmetic operators work end-to-end: Node -> Compiler -> VM -> Value.
Currently VM has add/sub/mul/div opcodes but cannot resolve var_ref "+".

## Problem Analysis

The pipeline gap:
1. Analyzer produces `var_ref {name: "+"}` for `(+ 1 2)`
2. Compiler emits `var_load` with symbol constant
3. VM hits `var_load` -> `InvalidInstruction`

Need:
- VM gets access to Env for var resolution
- Env has arithmetic builtins registered as Vars
- VM var_load resolves symbol -> Var -> Value

## Approach: Compiler-Level Intrinsic Recognition

Instead of full Env integration (which is Task 3.7), use a simpler approach:
the Compiler recognizes known arithmetic var_refs and emits direct opcodes.

This is similar to how many Clojure implementations optimize: `+` in call
position is compiled to an `add` opcode directly, not a var lookup + call.

### Compiler changes

When compiling a call_node where callee is var_ref with a known name:
- "+" -> emit args, emit `add`
- "-" -> emit args, emit `sub`
- "*" -> emit args, emit `mul`
- "/" -> emit args, emit `div`
- "mod" -> emit args, emit new `mod` opcode
- "rem" -> emit args, emit new `rem` opcode
- "<", ">", "<=", ">=" -> emit args, emit comparison opcode

This avoids needing Env in the Compiler/VM for basic arithmetic.

### New opcodes needed

- `mod` (0xB8) — Clojure mod semantics (always non-negative for positive divisor)
- `rem` (0xB9) — Clojure rem semantics (sign follows dividend)

### TDD steps

1. Red: Compiler emits `add` for `(+ 1 2)` call
2. Red: VM executes compiled `(+ 1 2)` via EvalEngine compare
3. Red: mod/rem opcodes
4. Red: comparison intrinsics via compiler
5. Refactor

## Log

- Added mod(0xB8), rem_(0xB9), eq(0xBA), neq(0xBB) opcodes
- Compiler: intrinsic recognition in emitCall — known 2-arg var_refs
  (+, -, *, /, mod, rem, <, <=, >, >=, =, not=) emit direct opcodes
- VM: added binaryMod, binaryRem, eq, neq handlers
- TreeWalk: added mod, rem, =, not= builtins
- EvalEngine: updated mismatch test to match test (+ now works in VM via intrinsic)
- Added compare tests for division, mod, equality
- All 318 tests pass
