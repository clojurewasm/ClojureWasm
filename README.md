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
- **Small binary** — ~4MB single executable (ReleaseSafe)
- **Single binary distribution** — `cljw build app.clj -o app`, runs without cljw installed
- **Wasm FFI** — call WebAssembly modules from Clojure (523 opcodes including SIMD + GC)
- **Dual backend** — bytecode VM (default) + TreeWalk interpreter (reference)
- **deps.edn compatible** — Clojure CLI subset (-A/-M/-X/-P, git deps, local deps)
- **1100+ vars** across 30+ namespaces (651/706 clojure.core)

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

### deps.edn Projects

```bash
# Download dependencies (git deps require explicit -P)
./zig-out/bin/cljw -P

# Run with aliases
./zig-out/bin/cljw -M:run                # Main opts
./zig-out/bin/cljw -X:build              # Exec function
./zig-out/bin/cljw -A:dev src/app.clj    # Extra paths
./zig-out/bin/cljw -Spath                # Show classpath

# Run tests
./zig-out/bin/cljw test                  # Auto-discover test/
./zig-out/bin/cljw test -A:test          # With alias
```

Supports `:local/root`, `:git/url`+`:git/sha`, `:deps/root`, transitive deps.
No Maven/Clojars support (git deps and local deps only).

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

**Core Language**

| Namespace              | Vars   | Description                          |
|------------------------|--------|--------------------------------------|
| clojure.core           | 651/706| Core language functions              |
| clojure.core.protocols | 10/11  | CollReduce, IKVReduce, Datafiable    |
| clojure.core.reducers  | 22/22  | Parallel fold, monoid, reducers      |

**Standard Library**

| Namespace          | Vars   | Description                    |
|--------------------|--------|--------------------------------|
| clojure.string     | 21/21  | String manipulation            |
| clojure.math       | 45/45  | Math functions                 |
| clojure.set        | 12/12  | Set operations                 |
| clojure.walk       | 10/10  | Tree walking                   |
| clojure.zip        | 28/28  | Zipper data structure          |
| clojure.data       | 5/5    | Data diff                      |
| clojure.edn        | 2/2    | EDN reader                     |
| clojure.template   | 2/2    | Code templates                 |
| clojure.xml        | 7/9    | XML parsing (pure Clojure)     |
| clojure.datafy     | 2/2    | datafy/nav protocols           |
| clojure.instant    | 3/5    | #inst reader, RFC3339 parser   |
| clojure.uuid       | —      | #uuid data reader (reader only)|

**Spec**

| Namespace              | Vars   | Description                    |
|------------------------|--------|--------------------------------|
| clojure.spec.alpha     | 87/87  | Spec validation, s/def, s/valid?|
| clojure.spec.gen.alpha | 54/54  | Spec generators                |
| clojure.core.specs.alpha| 1/1   | Spec for core macros           |

**Dev & Test**

| Namespace          | Vars   | Description                    |
|--------------------|--------|--------------------------------|
| clojure.test       | 38/39  | Test framework                 |
| clojure.test.tap   | 7/7    | TAP output formatter           |
| clojure.repl       | 11/13  | doc, dir, apropos, source, pst |
| clojure.pprint     | 22/26  | Pretty printing, print-table   |
| clojure.stacktrace | 6/6    | Stack trace utilities          |
| clojure.main       | 16/20  | REPL, script loading, ex-triage|

**IO & System**

| Namespace              | Vars   | Description                    |
|------------------------|--------|--------------------------------|
| clojure.java.io        | 19/19  | File I/O (Zig-native)         |
| clojure.java.shell     | 5/5    | Shell commands (sh)            |
| clojure.java.browse    | 2/2    | Open URL in browser            |
| clojure.java.process   | 5/9    | Process API (Clojure 1.12)     |

**Infrastructure (stubs — requireable, API surface for compatibility)**

| Namespace              | Vars   | Description                    |
|------------------------|--------|--------------------------------|
| clojure.core.server    | 7/11   | Socket REPL, prepl (partial)   |
| clojure.repl.deps      | 3/3    | Dynamic lib addition (stub)    |

**ClojureWasm Extensions**

| Namespace          | Vars   | Description                    |
|--------------------|--------|--------------------------------|
| cljw.wasm          | 17/17  | WebAssembly FFI                |
| cljw.http          | 6/6    | HTTP server/client             |

**Not implemented** (JVM-only): clojure.reflect, clojure.inspector, clojure.java.javadoc, clojure.test.junit

### Wasm FFI

Call WebAssembly modules directly from Clojure:

```clojure
(require '[cljw.wasm :as wasm])

(def mod (wasm/load "add.wasm"))
(def add (wasm/fn mod "add" [:i32 :i32] :i32))
(add 1 2)  ;=> 3
```

- 523 opcodes (236 core + 256 SIMD + 31 GC)
- All Wasm 3.0 proposals (9/9 including GC, function references, exception handling)
- WASI support (file I/O, clock, random, args, environ)
- Multi-module linking with cross-module imports
- Predecoded IR with superinstructions for optimized dispatch

> **Performance note**: The Wasm runtime ([zwasm](https://github.com/clojurewasm/zwasm))
> uses Register IR with ARM64/x86_64 JIT. Full Wasm 3.0 support (all 9 proposals
> including GC, function references, SIMD, exception handling).
> zwasm wins 10/21 benchmarks vs wasmtime, with ~5x smaller binary.

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
- **Bootstrap cache** — core.clj pre-compiled at build time (~5ms restore)
- **deps.edn projects** — Clojure CLI compatible config (git deps, local deps, aliases)

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
└── wasm/                       WebAssembly runtime (523 opcodes)

bench/                          31 benchmarks, multi-language
test/                           81 Clojure test files (54 upstream ports)
```

The [`.dev/`](.dev/) directory contains design decisions, optimization logs,
and development notes. Some may be outdated, but may interest those curious
about how the project evolved.

## Benchmarks

The benchmark suite is in [`bench/`](bench/) with 31 programs
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
bash test/e2e/run_e2e.sh       # End-to-end tests (6 wasm)
bash test/e2e/deps/run_deps_e2e.sh  # deps.edn E2E tests (14)
```

81 Clojure test files including 54 upstream test ports with 600+ deftests.
All tests verified on both VM and TreeWalk backends.

## Future Plans

- **JIT expansion** — float operations, function calls, broader loop patterns
- **Generational GC** — nursery/tenured generations for throughput
- **Persistent data structures** — HAMT/RRB-Tree implementations
- **wasm_rt** — compile Clojure to run *inside* WebAssembly

## Potential Use Cases

Once production-ready, ClojureWasm could enable workloads where the JVM
is too heavy:

- **Serverless functions** — ~4MB image + ~4ms cold start for AWS Lambda
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
