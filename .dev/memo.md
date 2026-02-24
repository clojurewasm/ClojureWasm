# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Phase 98 IN-PROGRESS** (Clean Sweep: Zero Negatives + Zone 0)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files. 6/6 e2e. 14/14 deps e2e
- Binary: 4.76MB. Startup: 4.2ms. RSS: 7.6MB
- Zone violations: 16 (baseline, Z1-Z3 done) → remaining 16 are test-only + architectural
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

Z3 complete. Remaining 16 violations breakdown:
- 10: tree_walk.zig test blocks → registry.zig (test-only)
- 2: bootstrap.zig → collections/registry (test-only)
- 3: analyzer.zig → macro/rewrites/constructors (architectural: analyzer needs macro expansion)
- 1: vm.zig → arithmetic.zig (architectural: VM needs arith opcodes)

Next: Assess if further reduction is worthwhile or if 16 is the accepted baseline.

## Previous Task

Z3: Vtable/extract for remaining violations (30→16) — DONE.
- Extracted computeHash/mixCollHash → runtime/hash.zig (−2: collections, tree_walk)
- Moved current_env → dispatch.zig (−3: lifecycle, pipeline, http_server)
- FnProto tracing → dispatch vtable (−1: gc→chunk)
- VM/TreeWalk multimethods/metadata/predicates → dispatch vtable (−5)
- Loader functions → dispatch vtable (−2: cache, bootstrap→loader)
- Removed unused builtin_collections import from vm.zig (−1)

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

Part B: Zone Violation Reduction (126 → 16)
Z1: Reclassify wasm types → runtime (−8)         ✓ DONE (126→118)
Z2: Reclassify eval_engine/macro/ns_loader → lang (−88) ✓ DONE (118→30)
Z3: Vtable/extract for remaining violations (−14)   ✓ DONE (30→16)
```

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED.
P2: spec (I-022) → deferred.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 16)
- Phase 98 plan: `.claude/plans/shiny-frolicking-dijkstra.md`
- 16 remaining violations: 12 test-only + 4 architectural (accepted)
