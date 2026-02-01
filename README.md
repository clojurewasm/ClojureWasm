# ClojureWasm

An independent Clojure runtime implemented in Zig, optimized for high-performance native execution and deep WebAssembly runtime integration.

## Project Structure

```
src/
├── api/                  Public API for embedding (eval, REPL, plugin)
├── common/               Shared across both native and wasm_rt tracks
│   ├── reader/           Tokenizer, Reader, Form types
│   ├── analyzer/         Analyzer, Node types, macro expansion
│   ├── bytecode/         OpCode definitions, constant table
│   ├── value/            Value type definitions
│   └── builtin/          Built-in function semantics (shared logic)
├── native/               Native binary track (fast single-binary)
│   ├── vm/               VM execution engine (NaN boxing)
│   ├── gc/               Custom garbage collector
│   └── optimizer/        Constant folding, fused reduce, etc.
├── wasm_rt/              Wasm runtime track (leverage Wasm GC/tooling)
│   ├── vm/               Wasm-targeted VM
│   ├── gc_bridge/        WasmGC integration
│   └── wasm_backend/     WasmBackend trait implementation
└── wasm/                 Wasm InterOp (shared by both tracks)

clj/                      Clojure source for AOT compilation (@embedFile)
test/
├── unit/                 Per-module unit tests
├── e2e/                  End-to-end tests
└── upstream/             Upstream test suites (SCI, CLJS, Clojure)
docs/
├── adr/                  Architecture Decision Records
└── developer/            Developer guides
bench/                    Benchmark suite
scripts/                  CI and quality-gate scripts
```

### Dual-Track Architecture

The codebase supports two execution tracks selected at **comptime**:

- **native/** — Single-binary, maximum performance. Uses NaN boxing and a custom GC.
- **wasm_rt/** — Targets WebAssembly runtimes, leveraging WasmGC and host tooling.

Both tracks share `common/` (reader, analyzer, bytecode, value, builtins) and `wasm/` (Wasm interop).
