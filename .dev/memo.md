# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Zone Cleanup COMPLETE** (16 → 0 violations)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files. 6/6 e2e. 14/14 deps e2e
- Binary: 4.76MB. Startup: 4.2ms. RSS: 7.6MB
- Zone violations: 0 (zero — fully clean architecture)
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

v0.4.0 release — all docs updated, ready for tag.

## Previous Task

HAMT crash fix + CI benchmark timeout fix + full doc update for v0.4.0.

## Task Queue

(empty)

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED.
P2: spec (I-022) → deferred.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 0)
- Zone checker now excludes test-only imports (after first `test "..."` in file)
- Phase 98 plan: `.claude/plans/shiny-frolicking-dijkstra.md` (COMPLETE)
