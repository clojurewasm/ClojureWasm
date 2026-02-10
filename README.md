# ClojureWasm

![Status: Pre-Alpha](https://img.shields.io/badge/status-pre--alpha-orange)
![License: EPL-1.0](https://img.shields.io/badge/license-EPL--1.0-blue)
![Zig 0.15.2](https://img.shields.io/badge/zig-0.15.2-f7a41d)

> **Status: Pre-Alpha / Experimental**
>
> ClojureWasm is under active development. APIs may change, and there are
> behavioral differences from reference Clojure. Bugs and rough edges are
> expected. See [DIFFERENCES.md](DIFFERENCES.md) for details.
>
> **Verified on**: macOS (Apple Silicon / aarch64). Linux x86_64 and
> aarch64 builds pass CI but have not been extensively tested.

A Clojure runtime written from scratch in Zig. No JVM, no transpilation —
a native implementation targeting behavioral compatibility with Clojure.

## Highlights

- **Fast startup** — ~4ms to evaluate an expression (ReleaseSafe)
- **Small binary** — ~3MB single executable (ReleaseSafe)
- **Single binary distribution** — `cljw build app.clj -o app`, runs without cljw installed
- **Wasm FFI** — call WebAssembly modules from Clojure (461 opcodes including SIMD)
- **Dual backend** — bytecode VM (default) + TreeWalk interpreter (reference)
- **795 vars** across 16 namespaces (593/706 clojure.core)

## Getting Started

### Prerequisites

- [Zig 0.15.2](https://ziglang.org/download/) (or `nix develop` for a pinned environment)

### Build

```bash
zig build                     # Debug build
zig build -Doptimize=ReleaseSafe  # Optimized build
```

### Run

```bash
./zig-out/bin/cljw -e '(println "Hello, world!")'   # Evaluate expression
./zig-out/bin/cljw script.clj                        # Run a file
./zig-out/bin/cljw                                   # Interactive REPL
```

### Build a Standalone Binary

```bash
./zig-out/bin/cljw build app.clj -o myapp
./myapp                         # Runs without cljw
```

### nREPL / CIDER

```bash
./zig-out/bin/cljw --nrepl-server --port=7888 app.clj
```

Connect from Emacs CIDER or any nREPL client. 14 ops supported (eval, complete,
info, stacktrace, eldoc, etc.).

## Features

### Namespaces

Each namespace targets behavioral equivalence with its Clojure JVM counterpart.
Known divergences are documented in [DIFFERENCES.md](DIFFERENCES.md).

| Namespace          | Vars | Description                    |
|--------------------|------|--------------------------------|
| clojure.core       | 593  | Core language functions        |
| clojure.string     | 21   | String manipulation            |
| clojure.math       | 45   | Math functions                 |
| clojure.set        | 12   | Set operations                 |
| clojure.walk       | 10   | Tree walking                   |
| clojure.zip        | 28   | Zipper data structure          |
| clojure.test       | 32   | Test framework                 |
| clojure.repl       | 11   | doc, dir, apropos, source, pst |
| clojure.pprint     | 9    | Pretty printing, print-table   |
| clojure.data       | 3    | Data diff                      |
| clojure.edn        | 1    | EDN reader                     |
| clojure.template   | 2    | Code templates                 |
| clojure.stacktrace | 6    | Stack trace utilities          |
| clojure.java.io    | 7    | File I/O (Zig-native)          |
| clojure.java.shell | 5    | Shell commands (sh)            |
| cljw.http          | 6    | HTTP server/client             |

### Wasm FFI

Call WebAssembly modules directly from Clojure:

```clojure
(require '[cljw.wasm :as wasm])

(def mod (wasm/load "add.wasm"))
(def add (wasm/fn mod "add" [:i32 :i32] :i32))
(add 1 2)  ;=> 3
```

- 461 opcodes (225 core + 236 SIMD)
- WASI support (file I/O, clock, random, args, environ)
- Multi-module linking with cross-module imports
- v128 SIMD operations
- Predecoded IR with superinstructions for optimized dispatch

> **Performance note**: The Wasm runtime is a pure interpreter (no JIT),
> approximately 10-30x slower than wasmtime for compute-heavy modules.
> Module load time is faster (~4ms vs ~5ms). Wasm JIT compilation and
> wasmtime integration are planned as future optimization paths.

### Server & Networking

```clojure
(require '[cljw.http :as http])

(defn handler [req]
  (case (:uri req)
    "/hello" {:status 200 :body "Hello!"}
    {:status 404 :body "Not Found"}))

(http/run-server handler {:port 8080})
```

- Ring-compatible handler model
- HTTP client: `http/get`, `http/post`, `http/put`, `http/delete`
- nREPL in built binaries (`./myapp --nrepl 7888`)
- SIGINT/SIGTERM graceful shutdown with hooks

### Internals

- **NaN-boxed Value** — 8-byte tagged representation (float pass-through, i48 integer, 40-bit heap pointer)
- **MarkSweep GC** — allocation tracking, free-pool recycling, safe points
- **Bytecode VM** — 75 opcodes, superinstructions, fused branch ops
- **ARM64 JIT** — hot integer loop detection with native code generation
- **Bootstrap cache** — core.clj pre-compiled at build time (~4ms restore)
- **Zero-config projects** — auto-detect `src/`, `cljw.edn` optional

## Project Structure

```
src/
├── main.zig                    CLI entry point
├── root.zig                    Library root
├── clj/clojure/                Clojure source files
│   ├── core.clj                Core library (~2400 lines)
│   └── string.clj, set.clj... Standard library namespaces
│
├── reader/                     Stage 1: Source → Form
├── analyzer/                   Stage 2: Form → Node
├── compiler/                   Stage 3: Node → Bytecode
├── vm/                         Stage 4a: Bytecode execution (+ JIT)
├── evaluator/                  Stage 4b: TreeWalk interpreter
│
├── runtime/                    Core types, GC, environment
├── builtins/                   Built-in functions (27 modules)
├── regex/                      Regex engine
├── repl/                       nREPL server, line editor
└── wasm/                       WebAssembly runtime (461 opcodes)

bench/                          31 benchmarks, multi-language
test/                           62 Clojure test files (39 upstream ports)
```

The [`.dev/`](.dev/) directory contains design decisions, optimization logs,
and development notes. Some may be outdated, but may interest those curious
about how the project evolved.

## Benchmarks

The benchmark suite is in [`bench/benchmarks/`](bench/benchmarks/) with 31 programs
covering computation, collections, higher-order functions, GC pressure, and Wasm.

```bash
# Requires hyperfine
bash bench/run_bench.sh                  # All benchmarks (ReleaseSafe)
bash bench/run_bench.sh --quick          # Quick check (1 run)
bash bench/run_bench.sh --bench=fib_recursive  # Single benchmark
```

## Testing

```bash
zig build test                  # 1,300+ Zig test blocks
bash test/e2e/run_e2e.sh       # End-to-end tests
```

62 Clojure test files including 39 upstream test ports with 735 deftests.
All tests verified on both VM and TreeWalk backends.

## Future Plans

- **Wasm FFI acceleration** — Wasm JIT compilation and optional wasmtime
  integration via its C API
- **JIT expansion** — float operations, function calls, broader loop patterns
- **Concurrency** — future, pmap, agent via Zig thread pool
- **Generational GC** — nursery/tenured generations for throughput
- **Dependency management** — deps.edn compatible (git/sha deps)
- **Persistent data structures** — HAMT/RRB-Tree implementations
- **wasm_rt** — compile Clojure to run *inside* WebAssembly

## Potential Use Cases

Once production-ready, ClojureWasm could enable workloads where the JVM
is too heavy:

- **Serverless functions** — ~3MB image + ~4ms cold start for AWS Lambda
  or Fly.io, eliminating JVM warm-up penalties
- **Wasm plugin host** — embed user-supplied .wasm modules as extensibility
  points (e.g., Cloudflare Workers-style logic, game scripting)
- **Edge / IoT** — run Clojure on Raspberry Pi or resource-constrained
  devices where a JVM runtime is impractical

## Acknowledgments

Built on [Clojure](https://clojure.org/) by Rich Hickey and
[Zig](https://ziglang.org/) by Andrew Kelley. Includes adapted Clojure
standard library code and ported test cases (EPL-1.0).
See [NOTICE](NOTICE) for attribution details.

## License

[Eclipse Public License 1.0](LICENSE) (EPL-1.0)

Copyright (c) 2026 chaploud

## Support

Developed in spare time alongside a day job. If you'd like to support
continued development, sponsorship is welcome via
[GitHub Sponsors](https://github.com/sponsors/chaploud).
