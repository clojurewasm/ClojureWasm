# T7.9: nREPL Middleware — CIDER Compatibility + Stacktrace

## Goal

Improve nREPL server for practical editor integration. Add missing ops
that CIDER/Calva expect, implement clojure.stacktrace namespace, and
handle edge cases discovered in T7.8 integration testing.

## Scope

### 1. Missing Ops (CIDER expects)

| Op        | Description                     | Impl |
| --------- | ------------------------------- | ---- |
| stdin     | Stdin input (stub, return done) | Stub |
| interrupt | Cancel eval (stub, return done) | Stub |

### 2. clojure.stacktrace Namespace

Port from Beta's `src/clj/clojure/stacktrace.clj` (38 lines):

- `root-cause`, `print-throwable`, `print-stack-trace`, `print-cause-trace`, `e`
- Minimal stubs (no JVM StackTraceElement)

### 3. Error Response Improvements

- Include `*e` binding on eval error (last exception)
- Include source location in error messages when available
- Include `pprint` key in eval response (CIDER uses for rendering)

### 4. describe Improvements

- Add `aux` info with `current-ns` to describe response
- Add `clojure` version info (for CIDER compatibility checks)

## Plan (TDD)

1. Red: test stdin op returns done
2. Green: implement opStdin (simple done reply)
3. Red: test interrupt op returns done
4. Green: implement opInterrupt
5. Add clojure.stacktrace.clj to clj/ directory
6. Red: test `(require 'clojure.stacktrace)` works
7. Green: add stacktrace.clj to bootstrap loader
8. Red: test eval error binds `*e`
9. Green: bind `*e` on eval error in opEval
10. Red: test describe includes aux info
11. Green: add aux and clojure version to opDescribe
12. Integration test with CIDER (manual verification)

## Log

### Session 1

1. Green: stdin op stub — returns done (CIDER expects this)
2. Green: interrupt op stub — returns done + session-idle
3. Green: describe improvements — Clojure version info, aux with current-ns
4. Green: REPL vars *1, *2, *3, *e — initialized at server start, updated in opEval
5. Integration tested:
   - `42` → `*1` = 42 ✓
   - `100` → `*2` = 42 (shifted) ✓
   - `200` → `*3` = 100 (shifted) ✓
   - Error → `*e` = error message string ✓

### Scope Reduction

- clojure.stacktrace namespace: DEFERRED — requires `ns`/`require` special forms
  which are not yet implemented. Will be addressed when namespace system is extended.
- `*e` currently binds error message string, not the thrown value itself.
  This is a limitation of the current error_ctx which only stores message strings.
