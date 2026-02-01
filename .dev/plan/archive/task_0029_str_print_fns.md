# Task 3.8: Runtime functions — str, pr-str, println, prn

## Goal

Add string conversion and I/O output builtins to ClojureWasm.

## Dependencies

- T3.5 (BuiltinDef registry) — completed

## Key Semantics

| Function  | Output target | Readable? | Separator | Trailing newline | Returns |
| --------- | ------------- | --------- | --------- | ---------------- | ------- |
| `str`     | (none)        | No        | (none)    | N/A              | String  |
| `pr-str`  | (none)        | Yes       | space     | N/A              | String  |
| `println` | stdout        | No        | space     | Yes              | nil     |
| `prn`     | stdout        | Yes       | space     | Yes              | nil     |

**Readable vs Non-readable:**

- Readable (pr-str, prn): strings quoted `"hello"`, chars as `\c`
- Non-readable (str, println): strings bare `hello`, chars as literal

**str special behavior:**

- `(str)` => `""`
- `(str nil)` => `""`
- `(str "hello")` => `"hello"` (no quotes)
- `(str 1 " " 2)` => `"1 2"` (concatenation, no separator)

## Plan

### Step 1: Add Value.formatStr (non-readable)

Add a method to Value that prints without quoting strings/chars.
This is the `str` counterpart to the existing `formatPrStr`.

### Step 2: Create src/common/builtin/strings.zig

Implement `strFn` and `prStrFn` as BuiltinFn functions.

### Step 3: Create src/common/builtin/io.zig

Implement `printlnFn` and `prnFn` as BuiltinFn functions.
Use stdout writer for output. Keep it simple (no output capture yet).

### Step 4: Register in registry.zig

Add strings and io modules to all_builtins. Update count test.

### Step 5: EvalEngine compare tests

Add compare tests for all 4 builtins to verify VM/TreeWalk parity.

## Log

- Step 1: Added Value.formatStr (non-readable) — nil=>"", string unquoted, char as literal
- Step 2: Created strings.zig with strFn + prStrFn (12 unit tests)
- Step 3: Created io.zig with printlnFn + prnFn, output capture for tests (8 unit tests)
- Step 4: Registered in registry.zig (49 -> 53 builtins)
- Step 5: Added EvalEngine compare tests for str and pr-str
- All tests green
