# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25 complete (Wasm InterOp FFI)
- Phase 26.R complete (wasm_rt Research — archived, implementation deferred)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction pivot**: Native production track. wasm_rt deferred.
- **Next: Phase 27** — NaN Boxing (Value 48B -> 8B)

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
3. 27.3: Switch internal representation to NaN-boxed u64 ← CURRENT
4. 27.4: Benchmark and verify performance gains

## Current Task

27.3: Switch Value internal representation from union(enum) to NaN-boxed u64.
Only value.zig internals change — all external code already uses accessor API.
Sub-steps per plan:
1. Create HeapString wrapper for []const u8 slices
2. Heap-allocate Symbol and Keyword (init* signatures need allocator)
3. Rewrite Value as opaque u64 wrapper with NaN boxing bit manipulation
4. Implement all tag()/init*/as* with bit ops
5. Handle i64→i48 narrowing (overflow → float promotion)
6. Update GC to trace NaN-boxed heap pointers
7. Update value.zig internal methods (formatPrStr, eql, hash, etc.)

## Previous Task

27.2 DONE (27.2a-27.2i): Migrated all ~44 source files to Value accessor API.
Groups: leaf builtins → core builtins → infrastructure → execution core.
Patterns: Value{.tag=x}→init*, switch(v){.tag=>|p|}→switch(v.tag()){.tag=>v.as*()},
direct field access→as*(), @tagName(v)→@tagName(v.tag()).
Only value.zig retains old-style union access (internal implementation).

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
