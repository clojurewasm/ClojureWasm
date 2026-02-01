# T4.13 — Wasm target (wasm32-wasi)

## Goal

Build and run ClojureWasm as a wasm32-wasi module using wasmtime.

## Design

Add a `wasm` build step to build.zig that cross-compiles the CLI for
wasm32-wasi. The existing code uses `std.posix.STDIN_FILENO` etc. which
may need Wasm-compatible alternatives.

### Features

- `zig build wasm` produces a .wasm binary
- `wasmtime clj-wasm.wasm -e "(+ 1 2)"` prints `3`
- REPL works over WASI stdin/stdout

### Dependencies

- wasmtime in dev shell (already in flake.nix)
- Zig 0.15 wasm32-wasi cross-compilation support

## Plan

1. Red: Try `zig build -Dtarget=wasm32-wasi` and identify compilation errors
2. Green: Fix portability issues, add wasm build step to build.zig
3. Test with wasmtime
4. Verify REPL and -e mode both work

## Log

### Session 1

1. Tried `zig build -Dtarget=wasm32-wasi` — compiled without errors on first try
2. wasmtime tests passed:
   - `(+ 1 2)` → 3
   - `(map inc [1 2 3])` → (2 3 4)
   - REPL via stdin pipe works
   - `(defn fib ...)` with TreeWalk works (VM has pre-existing var_load bug)
3. Added `wasm` build step to build.zig with explicit wasm32-wasi target
4. `zig build wasm -Doptimize=ReleaseSmall` produces 207KB .wasm binary
5. Native and Wasm outputs coexist: `clj-wasm` and `clj-wasm.wasm`
6. All 580 native tests pass (Wasm tests run via wasmtime CLI)
