# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 22c complete (A, BE, B, C, CX, R, D, 20-23, 22b, 22c)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- Phase 22c complete — loop ends here
- Next phase: 24 (optimize) per roadmap
- F96 resolved: VM protocol compilation done
- Blockers: none

## Task Queue

Phase 22c — COMPLETE (all 16 tasks done)

## Current Task

(none — Phase 22c complete)

## Previous Task

F96: VM protocol compilation
- Added defprotocol (0x4A) + extend_type_method (0x4B) opcodes
- Compiler: emitDefprotocol + emitExtendType (removed InvalidNode fallback)
- VM: defprotocol/extend_type_method handlers + protocol_fn dispatch in performCall
- bootstrap.callFnVal: added .protocol_fn case for cross-backend dispatch
- tree_walk.zig: made valueTypeKey pub for bootstrap access
- vm.zig: duplicated mapTypeKey/valueTypeKey (avoid circular imports)
- Added direct (non-eval) protocol tests: 5 tests, 18 assertions, both backends
- F96 removed from checklist.md

## Handover Notes

- **Phase 22c**: Complete. 16 tasks, all done. Gap analysis: `.dev/plan/test-gap-analysis.md`
- **F96**: Resolved. Protocols now compile to VM bytecode and work on both backends.
- Roadmap: `.dev/plan/roadmap.md`
- Test porting rules: `.claude/rules/test-porting.md`
- Interop patterns: `.claude/references/interop-patterns.md`
- Zig tips: `.claude/references/zig-tips.md`
- Beta references (for Phase 24+):
  - Error: `ClojureWasmBeta/src/base/error.zig`
  - Concurrency: `ClojureWasmBeta/src/lib/core/concurrency.zig`
  - Value: `ClojureWasmBeta/src/base/value.zig` (NaN boxing reference)
