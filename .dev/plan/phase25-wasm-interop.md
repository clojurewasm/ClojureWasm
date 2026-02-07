# Phase 25: Wasm InterOp Plan

## 1. Goals & Principles

- FFI to Wasm modules: Call .wasm functions from Clojure code
- Type-safe boundary: Verify signatures at load time
- zware first: Pure Zig runtime, no external dependencies
- Incremental: numeric -> strings -> host functions -> WASI -> WIT
- Both backends: wasm/load and wasm/fn in VM and TreeWalk (D6)
- TDD: Each sub-phase starts with failing tests

## 2. Prerequisites (Research at Session Start)

- [ ] zware Zig 0.15.2 compatibility
- [ ] WASI Preview 2 stabilization status
- [ ] Component Model specification progress
- [ ] Zig wasm32-wasi target name changes (wasip1/wasip2?)

## 3. Sub-Phases

### 25.0: Infrastructure Setup
- Add zware to build.zig.zon
- Copy WAT test files from WasmResearch/examples/wat/
- Create src/wasm/types.zig
- Smoke test: load .wasm, call add(3,4) from Zig

### 25.1: wasm/load + wasm/fn (Manual Signatures)
API:
  (def mod (wasm/load "math.wasm"))
  (def add (wasm/fn mod "add" {:params [:i32 :i32] :results [:i32]}))
  (add 3 4)  ;=> 7

Files: src/wasm/{loader,runtime,interop,builtins}.zig
Type mapping: integer<->i32/i64, float<->f32/f64, boolean<->i32, nil<->void

### 25.2: Memory + String Interop
API:
  (wasm/memory-write mod offset bytes)
  (wasm/memory-read mod offset length)
Files: src/wasm/interop.zig (extend)

### 25.3: Host Function Injection
API:
  (wasm/load "plugin.wasm" {:imports {"env" {"log" (fn [n] (println n))}}})
Files: src/wasm/host_functions.zig
Uses callFnVal (D36) for Clojure->Wasm callbacks

### 25.4: WASI Preview 1 Basics
API:
  (def tool (wasm/load-wasi "tool.wasm" {:args ["--help"]}))
  (wasm/call tool "_start")
Files: src/wasm/wasi.zig
Scope: fd_write, fd_read, proc_exit, args_get, environ_get

### 25.5: WIT Parser + Module Objects
API:
  (def img (wasm/load-wit "resize.wasm"))
  (img/resize-image buf 800 600)
Files: src/wasm/wit_parser.zig
Type mapping per SS4 table in future.md

## 4. File Layout

src/wasm/
  types.zig          — WasmModule, WasmInstance, WasmValue
  loader.zig         — .wasm binary loading
  runtime.zig        — Module instantiation, lifecycle
  interop.zig        — Value <-> Wasm type conversion
  host_functions.zig — Clojure fn -> Wasm host function
  wasi.zig           — WASI Preview 1
  wit_parser.zig     — WIT file parser
  builtins.zig       — wasm/load, wasm/fn builtins

## 5. Testing Strategy

- Zig unit tests in each src/wasm/*.zig
- .clj integration tests in test/wasm/
- WAT test files pre-compiled from WasmResearch
- Both VM + TreeWalk (D6)

## 6. References

- .dev/future.md SS1, SS4, SS6, SS15
- WasmResearch/docs/ (5 investigation documents)
- WasmResearch/examples/wat/ (8 WAT test modules)
- WasmResearch/examples/wit/ (math.wit)
