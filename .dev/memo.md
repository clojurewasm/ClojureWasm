# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Phase 98 IN-PROGRESS** (Clean Sweep: Zero Negatives + Zone 0)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files. 6/6 e2e. 8/14 deps e2e (6 pre-existing)
- Binary: 4.52MB. Startup: 4.2ms. RSS: 7.6MB
- Zone violations: 118 (baseline, Z1 done) → target: 0
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

Part B in progress: Zone Violation Reduction.
Next: Z2 — Reclassify macro/ns_loader → engine (target −13 violations).

## Previous Task

Z1: Reclassify wasm types → runtime (−8 violations) — DONE.
Moved types.zig→runtime/wasm_types.zig, builtins.zig→lang/lib/cljw_wasm_builtins.zig,
wit_parser.zig→runtime/wasm_wit_parser.zig. Replaced bootstrap.callFnVal→dispatch.callFnVal.

## Task Queue

```
Part A: Test/Leak Fixes
T1: Fix pprint *print-level* (1 FAIL)         ✓ DONE
T2: Fix into + reducers reify dispatch (11 FAIL)  ✓ DONE
T3: Fix deps E2E stderr messages (3 FAIL)        ✓ DONE
T4: Fix deps E2E :deps/root support (1 FAIL)      ✓ DONE
T5: Fix deps E2E transitive local dep (1 FAIL)     ✓ DONE
T6: Fix deps E2E transitive git dep (1 FAIL)       ✓ DONE
T7: Fix GPA memory leaks in protocol init        ✓ DONE

Part B: Zone Violation Reduction (126 → 0)
Z1: Reclassify wasm types → runtime (−8)         ✓ DONE (126→118)
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
