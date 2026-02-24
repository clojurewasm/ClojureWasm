# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **All phases through 97 COMPLETE**
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- Wasm engine: zwasm v1.1.0 (GitHub URL dependency, build.zig.zon)
- 68 upstream test files (68/68 passing). 6/6 e2e. 8/14 deps e2e (6 pre-existing)
- Binary: 4.52MB (wasm=true). Startup: 4.2ms. RSS: 7.6MB
- Baselines: `.dev/baselines.md` (threshold 4.8MB binary, 6.0ms startup)
- Zone violations: 126 (baseline, enforced by `scripts/zone_check.sh --gate`)

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

**4-zone layered architecture** (D109). Enforced by commit gate.
- Layer 0: `runtime/` — foundational types (no upward imports)
- Layer 1: `engine/` — processing pipeline (imports runtime/ only)
- Layer 2: `lang/` — Clojure builtins/interop (imports runtime/ + engine/)
- Layer 3: `app/` — CLI/REPL/Wasm (imports anything)

## Current Task

None — awaiting user direction for next phase.

## Previous Task

Phase 97 (Architecture Refactoring) — COMPLETE.
- R0-R7: Vtable extraction, bootstrap decomposition, dependency fixes
- R8: Directory rename to 4-zone layout
- R9: Split main.zig (2,343 LOC → 81 LOC + cli/runner/test_runner)
- R10: Zone enforcement in commit gate (baseline 126)
- R11: Structural integrity audit (clean — no violations)
- R12: Known issues resolution (I-011, I-012, I-013, I-023, I-024 all RESOLVED)

## Task Queue

```
(empty — next phase requires user input)
```

## Next Phase Candidates

From roadmap.md Phase Tracker (Tier 4):
- Phase 86: Distribution (Homebrew, signed releases, Docker)
- Phase 89: Performance Optimization (chunked processing, generational GC)
- Phase 90: JIT Expansion
- Phase 92: Security Hardening
- Phase 93: LSP Foundation

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED (I-011, I-012 fixed in R12).
P2: CollFold (I-021), spec (I-022) → deferred to Phase B.13/B.15. I-023/024 RESOLVED.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- CLAUDE.md binary threshold updated to 4.8MB (post All-Zig migration)
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 126)
- Refactoring analysis: `private/refactoring-analysis-2026-02-24.md`
- NextCW retrospective: `../NextClojureWasm/private/retrospective/`
- CONTRIBUTING.md at `.dev/CONTRIBUTING.md`
- Architecture v2 design: `.dev/archive/interop-v2-design.md` (archived)
