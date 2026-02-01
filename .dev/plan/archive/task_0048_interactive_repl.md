# T4.12 — Interactive REPL

## Goal

Replace the version stub with a working Read-Eval-Print Loop.

## Design

Simple line-by-line REPL with balanced-delimiter detection for multi-line input.
No line editing or history (deferred to future).

### Features

- `user=> ` prompt
- Read lines until delimiters are balanced
- Evaluate via TreeWalk (default) or VM (--vm flag)
- Print result
- Error handling: print error, continue loop
- Exit on EOF (Ctrl-D) or `(exit)`

### Dependencies

- std.io.getStdIn() for reading
- Existing evalString / evalStringVM

## Plan

1. Red: Test that REPL starts and responds to input (manual test)
2. Green: Implement REPL loop in main.zig
3. Add multi-line support (paren balancing)
4. Test error recovery

## Log

### Session 1

1. Implemented `runRepl` in main.zig with:
   - Separate `line_buf` and `input_buf` to avoid memcpy alias
   - `readLine` helper (byte-by-byte File.read for Zig 0.15 compatibility)
   - Multi-line support via `countDelimiterDepth` (already existed)
   - Error recovery: prints error message, continues loop
   - EOF handling: Ctrl-D exits cleanly
2. Fixed Zig 0.15 API issues:
   - `File.reader()` and `File.writer()` require buffer args (new in 0.15)
   - `File.Reader` has no `readUntilDelimiterOrEof` — used raw `File.read` instead
   - `File.Writer` has no `print` — used `File.write` for all output
3. Fixed `@memcpy` alias panic: line_buf and input_buf were initially the same buffer
4. Verified: single expr, multi-line, defn, error recovery, collections, EOF
5. All 580 tests pass
