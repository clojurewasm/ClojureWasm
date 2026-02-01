# Task 3.15: CLI entry point

## Goal

Create a CLI executable that can:

1. `-e "expr"` — evaluate a Clojure expression and print result
2. `file.clj` — evaluate a Clojure file
3. (no args) — REPL stub (placeholder, print message)

## Pipeline

read source -> Reader -> Forms -> Analyzer (with macro expansion) -> Nodes -> TreeWalk eval

For now, only TreeWalk backend (no VM compilation).
bootstrap.evalString already implements the full pipeline.

## Plan

### Step 1: Create src/native/main.zig

- Parse CLI args: -e "expr" | filename | (none)
- Initialize Env, register builtins, load core.clj
- Evaluate and print result

### Step 2: Wire up in build.zig

- Add exe step for the CLI binary

### Step 3: Test manually

- `zig build` produces binary
- `./zig-out/bin/clojure-wasm -e "(+ 1 2)"` => 3

## Log

- Created src/main.zig with CLI arg parsing (-e, file, version)
- build.zig: exe step, run step, exe tests
- Hit Zig 0.15 "dependency loop detected" for self-referential BuiltinFn type
  - Named type alias `pub const BuiltinFn = *const fn(...Value) Value` triggers cycle
  - Workaround: inline fn pointer type directly in Value union field (ziggit.dev #4717)
- Value.BuiltinFn kept as named alias for use in var.zig/registry etc.
- Verified: clj-wasm (version), -e "(+ 1 2)" => 3, -e "(fib 10)" => 55, file.clj mode
- All tests pass
