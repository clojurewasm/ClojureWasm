# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25 complete (Wasm InterOp FFI)
- Phase 26.R complete (wasm_rt Research — archived, implementation deferred)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction pivot**: Native production track. wasm_rt deferred.
- **Phase 27 in progress** — NaN Boxing (Value 48B -> 8B, 27.3 complete, 27.4 next)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: 27 (NaN boxing) -> 28 (single binary) -> 29 (restructure)
-> 30 (robustness/nREPL) -> 31 (Wasm FFI deep)

## Task Queue

Phase 27 — NaN Boxing (detailed plan: phase27-nan-boxing.md):
1. ~~27.1: API layer~~ DONE
2. ~~27.2: Migrate call sites~~ DONE (27.2a-27.2i, 9 commits, all ~44 files)
3. ~~27.3: Switch internal representation~~ DONE (27.3a-27.3e, 5 commits)
4. 27.4: Benchmark and verify performance gains ← NEXT

## Current Task

27.4: Benchmark and verify performance gains.
- Run all benchmarks with ReleaseSafe
- Compare against pre-NaN-boxing baseline
- Record to bench/history.yaml
- Verify correctness with .clj file execution on both backends

## Previous Task

27.3 DONE (27.3a-27.3e): Switched Value from union(enum) to NaN-boxed enum(u64).
Sub-steps: (a) migrate internal methods, (b) migrate tests, (c) add allocator params,
(d) pointer-ize string/symbol/keyword, (e) NaN boxing switch.
Value: 48B → 8B. Integer range: i64 → i48 (overflow → float promotion).
20 files modified in 27.3e: value.zig core + all remaining union-style patterns.
i48 overflow handling added to clojure.math exact-arithmetic functions.
eval_engine.zig comptime tests converted to runtime tests (heap allocation).

## Handover Notes

- **Roadmap**: .dev/plan/roadmap.md — Phases 27-31 defined
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: 600+ call sites. Staged API migration planned.
  Prior attempt in 24B.1 failed (too invasive). New approach: API layer first.
  Prototype saved at `/tmp/vp1.zig` + `/tmp/vp2.zig`.
- **Single binary**: @embedFile for user .clj + .wasm. F7 (macro serialization) for AOT.
- **nREPL**: cider-nrepl op compatibility target. Modular middleware approach.
- **Skip vars**: 178 skipped — re-evaluate for Zig equivalents (threading, IO, etc.)
- **Directory restructure**: common/native/ -> core/eval/cli/ (Phase 29)
- **zware**: Pure Zig Wasm runtime. Phase 25 FFI uses it.
- **D76/D77**: Wasm Value variants + host function injection (Phase 25)
