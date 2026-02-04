# ClojureWasm Development Memo

Read this at session start. Roadmap: `.dev/plan/roadmap.md`

## Current State

- Phase: 17 (IO / Print Functions)
- Current task: T17.4
- Task file: N/A
- Last completed: T17.3 — slurp, spit (file IO, 2 builtins)
- Blockers: none
- Next: T17.4 — Standard input (read-line)

## Current Phase: 17

**Background**: Phase 16.5 completed Batch 2 test ports (multimethods, vars, volatiles, delays).
Total ported: 12 test files, 105 tests, 414 assertions on TreeWalk; 96 tests, 388 assertions on VM.
Plus SCI tests: 72 tests, 267 assertions on TreeWalk. Total: 296 done vars, 170 builtins.

**Goal**: Implement IO/print functions. File I/O (slurp/spit), stdin (read-line),
missing print variants (print, pr, newline, flush), string IO functions.

### Rules

1. **TDD**: Test each function before/after implementation
2. **Dual-Backend**: All new builtins work on both VM and TreeWalk
3. **Zig std.fs/std.io**: Use Zig stdlib for file and IO operations
4. **No dynamic vars yet**: _out_/_err_/_in_ deferred until binding (F85) is implemented

### Task Queue

| Task  | Type | Description                               | Notes                                 |
| ----- | ---- | ----------------------------------------- | ------------------------------------- |
| T17.1 | impl | Basic print functions                     | print, pr, newline, flush (io.zig)    |
| T17.2 | impl | String IO functions                       | print-str, prn-str, println-str       |
| T17.3 | impl | File IO: slurp and spit                   | Zig std.fs, encoding: UTF-8 only      |
| T17.4 | impl | Standard input: read-line                 | Zig stdin reader                      |
| T17.5 | test | Port printer.clj (partial)                | print-length, print-level if feasible |
| T17.6 | impl | System functions: nano-time, exit, getenv | Zig std.time, std.process, std.posix  |

### Completion Criteria

- print/pr/newline/flush working on both backends
- print-str/prn-str/println-str available
- slurp/spit functional for file read/write
- read-line working from stdin
- Test file for IO functions ported/created

---

## Permanent Reference

Policies that persist across phases. Do not delete.

### Implementation Policy

1. **Implement in Zig or .clj** — do not skip features that appear "JVM-specific"
2. **Keep .clj files unchanged from upstream** — if modification needed, add `UPSTREAM-DIFF:` comment
3. **Check `.dev/notes/java_interop_todo.md`** before skipping anything Java-like
   - Many Java patterns (`System/`, `Math/`) have Zig equivalents listed there
   - SKIP only if not listed AND truly impossible

### Reference Files

| File                               | Content                     |
| ---------------------------------- | --------------------------- |
| `.dev/notes/test_file_priority.md` | Test file priority list     |
| `.dev/notes/java_interop_todo.md`  | Java interop implementation |
| `.dev/status/vars.yaml`            | Var implementation status   |
| `.dev/checklist.md`                | F## deferred items          |
| `.dev/notes/decisions.md`          | D## design decisions        |
