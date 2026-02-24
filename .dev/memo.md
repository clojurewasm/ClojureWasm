# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 88C COMPLETE**
- **Phase 97 (Architecture Refactoring) IN-PROGRESS**
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files (68/68 passing). 6/6 e2e. 8/14 deps e2e (6 pre-existing)
- Binary: 4.52MB (wasm=true). Startup: 4.2ms. RSS: 7.6MB
- Baselines: `.dev/baselines.md` (threshold 4.8MB binary, 6.0ms startup)

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

**Architecture refactoring** (D109). Strict 4-zone layered architecture:
- Layer 0: `runtime/` — foundational types (no upward imports)
- Layer 1: `engine/` — processing pipeline (imports runtime/ only)
- Layer 2: `lang/` — Clojure builtins/interop (imports runtime/ + engine/)
- Layer 3: `app/` — CLI/REPL/Wasm (imports anything)

Plan: `.dev/refactoring-plan.md`. Rules: `.claude/rules/zone-deps.md`.

## Current Task

Phase 97 (Architecture Refactoring), sub-task R12: Known issues resolution (I-011〜I-024).

See `.dev/refactoring-plan.md` R12 section and `.dev/known-issues.md` for details.

## Previous Task

R11: Structural integrity audit — COMPLETE.
- Semantic aliasing scan: CLEAN. No violations found.
  - int/long/short/byte → intCoerceFn: known CW design (single integer type), not aliasing
  - float/double → floatCoerceFn: known CW design (f64), not aliasing
- Evaluator special-case scan: CLEAN. No violations found.
  - Evaluators use node type tags / opcodes, not library-symbol string comparisons
  - All library features correctly implemented as macros or builtin functions

## Task Queue

```
R12: Known issues resolution (I-011〜I-024)
```

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: finally catch (I-011), watch/validator catch (I-012) → fix in R12.
P2: CollFold (I-021), spec (I-022), pointer cast (I-023/024) → fix in R12.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Refactoring analysis: `private/refactoring-analysis-2026-02-24.md`
- NextCW retrospective: `../NextClojureWasm/private/retrospective/`
- CONTRIBUTING.md at `.dev/CONTRIBUTING.md`
- Architecture v2 design: `.dev/archive/interop-v2-design.md` (archived)
