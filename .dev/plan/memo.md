# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 28.1 complete (A, BE, B, C, CX, R, D, 20-28.1, 22b, 22c, 24.5)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Direction**: Native production track (D79). wasm_rt deferred.
- **Phase 28.1 COMPLETE** — Single Binary Builder MVP (1.7MB binary)
- **Phase 29 IN PROGRESS** — Codebase Restructuring (file splitting + D3)

## Strategic Direction

Native production-grade Clojure runtime. Differentiation vs Babashka:
- Ultra-fast execution (already 19/20 benchmark wins)
- Tiny single binary (< 2MB target with user code embedded)
- Wasm FFI (unique: call .wasm modules from Clojure)
- Zero-config project model (no deps.edn required)

Phase order: ~~27~~ -> ~~28.1~~ -> **29 (restructure)** -> 30 (robustness) -> 31 (FFI)

## Task Queue

Phase 29.1 — File Splitting:

1. **29.1a**: collections.zig → extract transient ops → transient.zig
2. **29.1b**: bootstrap.zig → extract hot_core_defs + callFnVal → bootstrap_hot.zig
3. **29.1c**: analyzer.zig → extract special forms → special_forms.zig
4. **29.1e**: vm.zig → extract performCall → vm_dispatch.zig
5. **29.1f**: value.zig → extract formatPrStr → value_format.zig

Phase 29.2 — D3 Violations:

6. **29.2a**: io.zig capture_* → RuntimeContext
7. **29.2b**: ns_ops.zig load_paths → Env
8. **29.2c-d**: numeric.zig prng, misc.zig gensym → Env

## Current Task

29.1a: Split builtin/collections.zig (3737L). Extract transient collection
builtins (TransientVector/Map/Set operations) into builtin/transient.zig.

## Previous Task

28.1 DONE: Single binary builder MVP. Binary trailer approach:
[cljw binary] + [.clj source] + [u64 size] + "CLJW" magic.
readEmbeddedSource() detects trailer at startup. handleBuildCommand()
creates embedded binary. *command-line-args* populated from argv.
ReleaseSafe: 1.7MB single binary. Verified with hello.clj + fib.clj.

## Known Issues from Phase 27

- 9 HeapString/Symbol/Keyword leaks at program exit (bootstrap allocations not freed)
  Root cause: GC does not yet trace NaN-boxed heap pointers.
  Impact: cosmetic (GPA leak warnings at exit). Correctness unaffected.
  Fix: Update gc.zig to trace Value's NanHeapTag pointers. Add as F-item.

## Handover Notes

- **Phase 28 plan**: .dev/plan/phase28-single-binary.md
- **Roadmap**: .dev/plan/roadmap.md — Phases 27-31 defined
- **wasm_rt archive**: .dev/plan/phase26-wasm-rt.md + src/wasm_rt/README.md
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **NaN boxing (D72)**: COMPLETE. Value 48B→8B. 17 commits (27.1-27.4).
- **Single binary**: Binary trailer approach (Deno-style). No Zig needed on user machine.
  Format: [cljw binary] + [.clj source] + [u64 size] + "CLJW" magic.
- **macOS signing**: Ad-hoc resign with `codesign -s - -f` after build.
  Proper section injection deferred.
