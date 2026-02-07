# Phase 25: Wasm InterOp Plan

## 1. Goals & Principles

- FFI to Wasm modules: Call .wasm functions from Clojure code
- Type-safe boundary: Verify signatures at load time
- zware first: Pure Zig runtime, no external dependencies
- Incremental: numeric -> strings -> WASI -> TinyGo -> host functions -> WIT
- Both backends: wasm/load and wasm/fn in VM and TreeWalk (D6)
- TDD: Each sub-phase starts with failing tests

## 2. Prerequisites (Researched 2026-02-07)

- [x] zware Zig 0.15.2 compatibility — **confirmed**. minimum_zig_version = "0.15.2".
      Repo: github.com/malcolmstill/zware, commit 7c505ed (2025-12-30).
      Has build.zig.zon, MIT license, alpha quality. SIMD/WasmGC unsupported.
- [x] WASI Preview 2 stabilization — WASI 0.2 released 2024-01, Wasmtime supports fully.
      However, Zig 0.15.2 stdlib only implements Preview 1 (wasi_snapshot_preview1).
      Preview 2 would require manual imports. **Use Preview 1 for Phase 25.**
- [x] Component Model — NOT in Wasm 3.0 (completed 2025-09). Still Phase 1 at W3C.
      WASI 1.0 expected 2026 H2-2027 H1. **Defer Component Model to future phase.**
- [x] Zig wasm32-wasi target — `wasm32-wasi` is correct. `wasip1`/`wasip2` rejected.
      Version suffixes (`.0.1.0`, `.0.2.0`) parse but generate identical P1 code.
- [x] TinyGo 0.40.1 — Available via homebrew. Compiles Go to Wasm with `-target=wasi`.
      TinyGo WASI modules need wasi_snapshot_preview1 imports (fd_write, proc_exit, random_get, etc.)
      zware has full built-in WASI P1 support (19 functions).

## 3. Sub-Phases

### 25.0: Infrastructure Setup [DONE]
- Add zware to build.zig.zon
- Copy WAT test files from WasmResearch/examples/wat/
- Create src/wasm/types.zig
- Smoke test: load .wasm, call add(3,4) from Zig

### 25.1: wasm/load + wasm/fn (Manual Signatures) [DONE]
API:
  (def mod (wasm/load "math.wasm"))
  (def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))
  (add 3 4)  ;=> 7
D76: wasm_module + wasm_fn Value variants.

### 25.2: Memory + String Interop [DONE]
API:
  (wasm/memory-write mod offset bytes)
  (wasm/memory-read mod offset length)

### 25.3: WASI Preview 1 + TinyGo [DONE]
- wasm/load-wasi: auto-registers wasi_snapshot_preview1 imports via zware builtins
- 19 WASI functions: fd_write, fd_read, proc_exit, random_get, args_*, environ_*, etc.
- TinyGo go_math.go: add, multiply, fibonacci, factorial, gcd, is_prime
- FFI examples: examples/wasm/01_basic.clj, examples/wasm/02_tinygo.clj

### 25.4: Host Function Injection [DONE]
API:
  (wasm/load "plugin.wasm" {:imports {"env" {"log" (fn [n] (println n))}}})
D77: Global trampoline + context table (256 slots), callFnVal dispatch.
Example: examples/wasm/03_host_functions.clj

### 25.5: WIT Parser + Module Objects
API:
  (def img (wasm/load-wit "resize.wasm"))
  (img/resize-image buf 800 600)
Files: src/wasm/wit_parser.zig
Type mapping per SS4 table in future.md

## 4. File Layout

src/wasm/
  types.zig    — WasmModule (load, loadWasi, memory), WasmFn, WASI registration
  builtins.zig — wasm/load, wasm/load-wasi, wasm/fn, wasm/memory-read, wasm/memory-write

test/wasm/src/
  go_math.go   — TinyGo source (add, multiply, fibonacci, factorial, gcd, is_prime)

examples/wasm/
  01_basic.clj   — WAT modules: add, fib, memory, strings
  02_tinygo.clj  — TinyGo: Go functions + Clojure HOF composition

## 5. Testing Strategy

- Zig unit tests in each src/wasm/*.zig
- .clj integration examples in examples/wasm/
- WAT test files pre-compiled from WasmResearch
- TinyGo precompiled 09_go_math.wasm (20KB)
- Both VM + TreeWalk (D6)

## 6. References

- .dev/future.md SS1, SS4, SS6, SS15
- WasmResearch/docs/ (5 investigation documents)
- WasmResearch/examples/wat/ (8 WAT test modules)
- WasmResearch/examples/wit/ (math.wit)
- ClojureWasmBeta/docs/presentation/demo/04_wasm.clj, 05_go_wasm.clj (reference demos)
- ClojureWasmBeta/test/wasm/src/go_math.go (reference TinyGo source)
