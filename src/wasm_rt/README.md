# wasm_rt — WebAssembly Runtime Track (Deferred)

Compile the ClojureWasm runtime to a .wasm binary runnable on
Wasmtime/WasmEdge/browsers.

## Status: Deferred (2026-02-07)

Research phase (26.R) complete. Implementation deferred pending:

- **WasmGC**: LLVM cannot emit WasmGC instructions. No timeline for support.
  All languages using WasmGC (Kotlin, Dart, Go) bypass LLVM with custom backends.
- **Wasmtime GC**: Cycle collection not implemented (deferred reference-counting only).
  Long-running Clojure programs would leak cyclic references.
- **WASI Threads**: wasi-threads withdrawn, shared-everything-threads at Phase 1.
  Clojure concurrency (STM, agents, futures) requires stable threading.

## Research Findings

Full analysis in `.dev/archive/phase26-wasm-rt.md`:

| Topic              | Finding                                          |
|--------------------|--------------------------------------------------|
| Compile probe      | 10 errors cataloged, all fixable via comptime     |
| Code organization  | D78: separate main_wasm.zig + comptime guards     |
| GC strategy        | MarkSweepGc works as-is on wasm32-wasi            |
| Stack depth        | 1MB default OK, 8MB for edge cases                |
| Backend selection  | Both VM + TreeWalk (D73 two-phase bootstrap)      |
| Modern Wasm specs  | WasmGC blocked, tail-call partial, SIMD deferred  |

## Revival Conditions

Revisit when ANY of:
1. LLVM gains WasmGC support (or Zig self-hosted backend adds it)
2. Wasmtime implements tracing GC for WasmGC objects
3. WASI shared-everything-threads reaches Phase 3+
4. A compelling use case justifies linear-memory-only Wasm deployment

## Alternative Path: Clojure-to-WasmGC Compiler

A future project could compile Clojure AST/bytecode directly to WasmGC
instructions (bypassing Zig/LLVM), similar to Kotlin/Wasm or dart2wasm.
This would be a separate project from the current Zig runtime.
