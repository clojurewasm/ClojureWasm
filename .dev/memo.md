# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Phase 98 IN-PROGRESS** (Clean Sweep: Zero Negatives + Zone 0)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files. 6/6 e2e. 8/14 deps e2e (6 pre-existing)
- Binary: 4.52MB. Startup: 4.2ms. RSS: 7.6MB
- Zone violations: 126 (baseline) → target: 0
- Plan: `.claude/plans/shiny-frolicking-dijkstra.md`

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

**4-zone layered architecture** (D109). Enforced by commit gate.
- Layer 0: `runtime/` — foundational types (no upward imports)
- Layer 1: `engine/` — processing pipeline (imports runtime/ only)
- Layer 2: `lang/` — Clojure builtins/interop (imports runtime/ + engine/)
- Layer 3: `app/` — CLI/REPL/Wasm (imports anything)

## Current Task

T3: Fix deps E2E stderr messages (3 FAIL → 0)
- cli.zig error messages don't match expected test output format
- T3a: `Error: git tag '` → `ERROR: Git tag "`
- T3b: backticks → single quotes, "fetch" → "download...first"
- T3c: add "(Leiningen)" to message text
- File: `src/app/cli.zig`

## Previous Task

T2: Fix `into` + reducers reify dispatch (11 FAIL → 0) — DONE.
Root cause: `callCollReduce` used `"map"` as type key instead of the reify type string.
Fix: Use `interop_dispatch.getReifyType(coll)` to get actual reify type for protocol lookup.

## Task Queue

```
Part A: Test/Leak Fixes
T1: Fix pprint *print-level* (1 FAIL)         ✓ DONE
T2: Fix into + reducers reify dispatch (11 FAIL)  ✓ DONE
T3: Fix deps E2E stderr messages (3 FAIL)
T4: Fix deps E2E :deps/root support (1 FAIL)
T5: Fix deps E2E transitive local dep (1 FAIL)
T6: Fix deps E2E transitive git dep (1 FAIL)
T7: Fix GPA memory leaks in protocol init

Part B: Zone Violation Reduction (126 → 0)
Z1: Reclassify wasm types → runtime (−8)
Z2: Reclassify macro/ns_loader → engine (−13)
Z3: Extract Form/Chunk → runtime (−2)
Z4: Vtable expansion for tree_walk/vm (−23)
Z5: Reclassify eval_engine registration (−54)
Z6: Remaining violations cleanup (−26)
```

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED.
P2: CollFold (I-021) — fixing in T2. spec (I-022) → deferred.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 126)
- Phase 98 plan: `.claude/plans/shiny-frolicking-dijkstra.md`
