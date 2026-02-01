# T4.1 — VM: Variadic Arithmetic (+, -, \*, /)

## Goal

Make the VM handle all arities of +, -, \*, / to match TreeWalk behavior:

- `(+)` → 0, `(*)` → 1
- `(- x)` → negation, `(/ x)` → reciprocal, `(+ x)` → x, `(* x)` → x
- `(+ a b c ...)` → left-fold

## Approach: Compiler-level expansion

Expand variadic arithmetic to sequences of binary opcodes at compile time.
No new opcodes needed. This keeps the VM simple and fast.

### Cases

| Arity | Expression  | Compiled bytecode                             |
| ----- | ----------- | --------------------------------------------- |
| 0     | `(+)`       | `const_load 0`                                |
| 0     | `(*)`       | `const_load 1`                                |
| 0     | `(-)`       | Error (ArityError)                            |
| 0     | `(/)`       | Error (ArityError)                            |
| 1     | `(+ x)`     | compile x (identity)                          |
| 1     | `(* x)`     | compile x (identity)                          |
| 1     | `(- x)`     | `const_load 0`, compile x, `sub`              |
| 1     | `(/ x)`     | `const_load 1.0`, compile x, `div`            |
| 2     | `(+ a b)`   | compile a, compile b, `add` (existing)        |
| 3+    | `(+ a b c)` | compile a, compile b, `add`, compile c, `add` |

### Changes

1. **compiler.zig `emitCall()`**: Expand intrinsic check from `args.len == 2`
   to handle all arities for +, -, \*, / specifically.
2. **No VM changes**: Binary opcodes already work.
3. **Tests**: EvalEngine.compare() tests for all arity combinations.
4. **mod/rem**: Keep 2-arg only (Clojure spec). Same for comparison ops.

## Plan

1. Red: Write EvalEngine compare test for `(+ 1 2 3)` — expect match, value 6
2. Green: Modify compiler emitCall to handle 3+ args for variadic intrinsics
3. Red: Write test for `(+)` → 0
4. Green: Handle 0-arg case in compiler
5. Red: Write test for `(- x)` → negation
6. Green: Handle 1-arg case for - and /
7. Red: Write test for `(* 2 3 4)` → 24
8. Green: Should already pass from step 2
9. Red: Write test for `(/ x)` → reciprocal
10. Green: Handle 1-arg / case
11. Refactor: Clean up, ensure all edge cases covered
12. Add remaining EvalEngine compare tests for full coverage

## Log

- Red: wrote EvalEngine compare test for `(+ 1 2 3)` — VM fails (3-arg intrinsic not handled)
- Green: refactored compiler emitCall into variadicArithOp + binaryOnlyIntrinsic split
  - `emitVariadicArith()`: handles 0/1/2/n args for +,-,\*,/
  - 0-arg: (+)→0, (\*)→1, (-) and (/) → ArityError
  - 1-arg: (+ x)→identity, (\* x)→identity, (- x)→negation via 0-x, (/ x)→reciprocal via 1.0/x
  - 2+ args: left-fold via repeated binary opcodes
  - Added ArityError to CompileError enum
- Added 9 EvalEngine compare tests: 0/1/3/5-arg +, 0-arg _, 1-arg -, 1-arg /, 3-arg -, _, /
- All 497 tests pass (including 9 new variadic tests)
