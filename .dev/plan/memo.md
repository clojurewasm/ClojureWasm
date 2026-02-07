# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 24 COMPLETE** — CW wins speed 19/20, 1 tied
- Next: Phase 24.5 (Mini-Refactor), then Phase 25 (Wasm InterOp)

## Task Queue

Phase 24.5 — Mini-Refactor (Pre-Wasm Cleanup):
1. 24.5.1: Dead code removal
2. 24.5.2: Naming consistency audit
3. 24.5.3: D3 violation audit and documentation
4. 24.5.4: File size documentation

## Current Task

24.5.3: D3 violation audit — catalog all module-level mutable state.

## Previous Task

24.5.2: Naming audit — conventions consistent. Import alias _mod suffix
inconsistency noted (Phase 27 scope). No changes needed.

## Handover Notes

- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Partial (D74 filter chains). General recursion remains. Critical for Phase 26.
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. Verify 0.15.2 compat at Phase 25 start.
- **WasmResearch**: Investigation repo with docs + WAT/WIT examples
