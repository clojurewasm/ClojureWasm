# ClojureWasm

An independent Clojure runtime implemented in Zig, targeting behavioral compatibility with Clojure JVM.

## Current State

Phase 3 complete. TreeWalk evaluator is the primary backend. VM has basic opcodes but is behind on Phase 3 features.

- Reader: full Clojure literal support (strings, numbers, keywords, symbols, collections, regex, metadata, reader macros)
- Analyzer: special forms (if, do, let, fn, def, defmacro, loop/recur, try/catch/throw, quote)
- TreeWalk evaluator: full evaluation with core.clj bootstrap
- VM: basic arithmetic, var/def, closures, recur (parity work pending)
- CLI: `-e`, file execution, REPL stub
- 70 built-in functions + core.clj macros (defn, when, cond, ->, ->>, and/or, if-let, etc.)

## Usage

```bash
# Build
nix develop   # enter dev shell
zig build

# Run
zig-out/bin/cljw --version
zig-out/bin/cljw -e "(+ 1 2)"
zig-out/bin/cljw script.clj

# Test
zig build test
zig build test -- "Reader basics"
```

## Project Structure

```
src/
├── main.zig                  CLI entry point
├── root.zig                  Library root (re-exports)
├── clj/
│   └── core.clj              Clojure bootstrap (defn, macros, HOFs)
│
├── common/                   Shared across both tracks
│   ├── value.zig             Value tagged union
│   ├── env.zig               Environment (holds namespaces)
│   ├── namespace.zig         Namespace (intern/find/refer)
│   ├── var.zig               Var (root + dynamic bindings)
│   ├── bootstrap.zig         core.clj loading + SCI tests
│   ├── eval_engine.zig       Dual-backend compare mode
│   ├── reader/               Tokenizer, Reader, Form
│   ├── analyzer/             Analyzer, Node, macro expansion
│   ├── bytecode/             OpCode, Chunk, FnProto
│   └── builtin/              Built-in function registry
│
├── native/                   Native single-binary track
│   ├── vm/                   Compiler + VM (bytecode backend)
│   ├── evaluator/            TreeWalk evaluator (reference backend)
│   ├── gc/                   GC (placeholder — arena allocator)
│   └── optimizer/            Optimizer (placeholder)
│
├── wasm_rt/                  Wasm runtime track (placeholder)
│   ├── vm/                   Wasm-targeted VM
│   └── gc/                   WasmGC integration (bridge + backend)
│
├── wasm/                     Wasm InterOp — FFI for external .wasm modules
│   (loader, runtime, interop, WIT parser — shared by both tracks)
│
├── repl/                     REPL + nREPL (built-in subsystem)
│   (repl, nrepl — interactive environment + tool integration)
│
└── api/                      Public API for embedding
    (eval, plugin — interface for using ClojureWasm as a library)

docs/adr/                     Architecture Decision Records
test/                         External test suites (placeholder)
.dev/                         Development plans, notes, checklists
```

### Dual-Track Architecture

The codebase supports two execution tracks:

- **native/** — Single-binary, maximum performance. Tagged union Value (NaN boxing deferred). Arena allocator (real GC deferred).
- **wasm_rt/** — Targets WebAssembly runtimes, leveraging WasmGC and host tooling. (Placeholder — implementation after native track matures.)

Both tracks share `common/` (reader, analyzer, bytecode, value, builtins).
`wasm/` provides FFI for calling external `.wasm` modules (`wasm/load`, `wasm/fn`, WIT support) — separate from `wasm_rt/` which is the internal runtime track.

Note: as the Wasm track matures, some `common/` modules (value, bytecode, builtins) may need track-specific variants due to different Value representations (externref/i31ref) and GC strategies.

### Directory Design Rationale

| Directory  | Role                                                               |
| ---------- | ------------------------------------------------------------------ |
| `common/`  | Reader, analyzer, bytecode — shared foundation                     |
| `native/`  | Native execution: VM, TreeWalk, GC, optimizer                      |
| `wasm_rt/` | Wasm runtime execution: VM + WasmGC (gc/ unifies bridge + backend) |
| `wasm/`    | FFI layer for external .wasm modules (both tracks)                 |
| `repl/`    | Built-in REPL + nREPL subsystem (not an external API)              |
| `api/`     | Embedding interface for external consumers                         |

## Architecture

- **Tagged union Value**: no NaN boxing yet (deferred for optimization)
- **Arena allocator**: bulk free per phase, real GC deferred
- **Dual backend**: TreeWalk (correct, primary) + VM (fast, partial)
- **core.clj bootstrap**: loaded via read+eval at startup (AOT @embedFile deferred)
- **Instantiated VM**: no threadlocal/global mutable state

## Benchmarks

11 benchmarks across 5 categories. See `bench/README.md` for full details.

```bash
bash bench/run_bench.sh                    # ClojureWasm only
bash bench/run_bench.sh --all              # All 8 languages
bash bench/run_bench.sh --bench=fib_recursive --hyperfine  # Single, precise
```

## License

TBD
