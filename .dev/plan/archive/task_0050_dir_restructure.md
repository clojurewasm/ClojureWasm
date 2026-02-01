# T4.14 — Directory Restructuring

## Goal

Create missing placeholder directories per README structure.

## Design

The README specifies `src/repl/` for REPL + nREPL code. Currently the REPL
is inline in main.zig. Create the directory stub for future extraction.

T4.15 (wasm_rt/gc reorganization) is also in scope for this phase.

## Plan

1. Create `src/repl/.gitkeep`
2. Verify existing stubs are present (wasm/, wasm_rt/, api/)
3. Check T4.15 scope — wasm_rt/gc/ already has gc_bridge/ and wasm_backend/

## Log

### Session 1

1. Created `src/repl/.gitkeep` — the only missing directory per README
2. Reorganized wasm_rt/: moved gc_bridge/ and wasm_backend/ under gc/ as
   gc/bridge/ and gc/backend/ respectively (matching README's wasm_rt/gc/)
3. All directories now match README Project Structure
4. All 580 tests pass
