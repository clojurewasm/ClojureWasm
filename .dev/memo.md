# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Phase 98 COMPLETE** (Clean Sweep: Zero Negatives + Zone 16)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files. 6/6 e2e. 14/14 deps e2e
- Binary: 4.76MB. Startup: 4.2ms. RSS: 7.6MB
- Zone violations: 14 (baseline — 12 test-only, 2 architectural)
- All test suites: PASS (0 failures)

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

**4-zone layered architecture** (D109). Enforced by commit gate.
- Layer 0: `runtime/` — foundational types (no upward imports)
- Layer 1: `engine/` — processing pipeline (imports runtime/ only)
- Layer 2: `lang/` — Clojure builtins/interop (imports runtime/ + engine/)
- Layer 3: `app/` — CLI/REPL/Wasm (imports anything)

## Current Task

Zone Cleanup: 16 → 0. Task 3: Vtable-ize interop rewrites/constructors.
See `memory/zone-cleanup-16-to-0.md` for full plan.

## Previous Task

Zone Cleanup Task 2: Move macro.zig → engine/ with vtable (15 → 14, −1 violation).

## Task Queue

- Task 3: Vtable-ize interop rewrites/constructors (−2 violations)
- Task 4: Move integration tests → lang/tests/ (−12 violations)

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED.
P2: spec (I-022) → deferred.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 14)
- 14 remaining violations: 12 test-only + 2 architectural
- Phase 98 plan: `.claude/plans/shiny-frolicking-dijkstra.md` (COMPLETE)
