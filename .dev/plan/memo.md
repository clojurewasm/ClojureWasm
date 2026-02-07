# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- All phases through 24C complete (A, BE, B, C, CX, R, D, 20-24, 22b, 22c)
- Phase 24.5 complete (mini-refactor)
- Phase 25 complete (Wasm InterOp FFI)
- Coverage: 526/704 clojure.core vars done (0 todo, 178 skip)
- **Phase 26.R COMPLETE** — wasm_rt Research (all 7 tasks done)
- **Phase 26 READY** — wasm_rt Implementation (21 tasks planned)

## Task Queue

Phase 26.R — wasm_rt Research:
1. ~~26.R.1: Compile Probe~~ DONE
2. ~~26.R.2: Code Organization Strategy~~ DONE
3. ~~26.R.3: Allocator and GC Strategy~~ DONE
4. ~~26.R.4: Stack Depth and F99 Assessment~~ DONE
5. ~~26.R.5: Backend Selection~~ DONE
6. ~~26.R.6: Modern Wasm Spec Assessment~~ DONE
7. ~~26.R.7: MVP Definition and Full Plan~~ DONE

Phase 26 — wasm_rt Implementation:
1. 26.1.1: Create main_wasm.zig entry point
2. 26.1.2: Update build.zig wasm_exe to use main_wasm.zig
3. 26.1.3: Comptime guard: registry.zig skip wasm/builtins on wasi
4. 26.1.4: Comptime guard: system.zig getenv on wasi
5. 26.1.5: Comptime guard: root.zig skip nrepl/wasm exports
6. 26.1.6: Verify `zig build wasm` compiles without errors
7. 26.2.1: stdout/stderr fd constants for wasi
8. 26.2.2: file_io.zig verify cwd() on WASI preopened dirs
9. 26.2.3: system.zig getEnvMap fallback on WASI
10. 26.2.4: main_wasm.zig arg parsing from process.args
11. 26.3.1: bootstrap.zig comptime guard for eval_engine exclusion
12. 26.3.2: bootstrap.zig comptime guard for dumpBytecodeVM
13. 26.3.3: Verify loadCore (TreeWalk bootstrap) on wasmtime
14. 26.3.4: Verify evalStringVMBootstrap (D73 hot recompile) on wasmtime
15. 26.3.5: Verify evalStringVM (user eval via VM) on wasmtime
16. 26.3.6: End-to-end: wasmtime cljw.wasm -- -e '(+ 1 2)' → 3
17. 26.4.1: Run core bootstrap test suite on wasmtime
18. 26.4.2: Verify slurp/spit with preopened dirs
19. 26.4.3: Verify GC triggers and collection
20. 26.4.4: Run benchmark subset on wasmtime
21. 26.4.5: Measure binary size and startup time

## Current Task

26.R.7: MVP Definition and Full Plan — COMPLETING (committing plan documents)

## Previous Task

26.R.6: Modern Wasm Spec Assessment — WasmGC not usable (LLVM).
Tail-call PoC works but unstable. SIMD/threads/EH deferred.
WASI P1 sufficient. All dynamic lang Wasm ports use linear memory GC.

## Handover Notes

- **Phase 26 plan**: .dev/plan/phase26-wasm-rt.md (building incrementally)
- **Optimization catalog**: .dev/notes/optimization-catalog.md
- **Optimization backlog**: .dev/notes/optimization-backlog.md (deferred + future items)
- **Phase 25 plan**: .dev/plan/phase25-wasm-interop.md
- **Benchmark history**: bench/history.yaml
- **F99**: Deferred. D74 covers pathological case. Not critical for Phase 26 MVP.
- **D78**: Code organization — separate main_wasm.zig + ~12 comptime guards
- **26.R findings**: WasmGC impossible (LLVM), both backends (VM+TW), WASI P1, MarkSweepGc as-is
- **Stack**: 1MB default OK, 8MB for edge cases (-W max-wasm-stack=8388608)
- **NaN boxing (D72)**: 600+ call sites. Deferred.
- **zware**: Pure Zig Wasm runtime. WASI P1 built-in (19 functions).
- **D76**: Wasm Value variants — wasm_module + wasm_fn in Value union
- **D77**: Host function injection — trampoline + context table (256 slots)
- **Compile probe PoC**: GPA, fs.cwd(), time, process.args all work on wasm32-wasi
- **WASI fd convention**: stdout=1, stderr=2 (same as POSIX, no std.posix needed)
