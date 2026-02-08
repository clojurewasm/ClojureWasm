# ClojureWasm

Clojure runtime written from scratch in Zig 0.15.2. Behavioral compatibility with Clojure JVM.

## Highlights

- **Ultra-fast startup**: ~3-4ms (vs Babashka 8ms, Python 11ms, Java 21ms)
- **Tiny binary**: ~2.8MB (ReleaseSafe)
- **Single binary distribution**: `cljw build app.clj -o app` — no runtime needed
- **Beats Babashka** on 19/20 benchmarks (speed), 20/20 (memory)
- **NaN-boxed Value**: 8 bytes per value (33% faster, 53% less memory vs tagged union)

## Features

### Language

- Full Clojure reader (EDN, reader macros, syntax-quote, regex, tagged literals)
- Dual backend: TreeWalk (reference) + bytecode VM (default, 9x faster)
- 660+ vars implemented across 14 namespaces (537/706 clojure.core)
- Persistent collections: list, vector, map, set (sorted variants included)
- Transient collections, chunked sequences
- Lazy sequences with GC-safe realization
- Protocols, defrecord, deftype, multimethods
- Destructuring (sequential, associative, nested)
- try/catch/throw, loop/recur, letfn, with-open
- Metadata system (with-meta, alter-meta!, vary-meta)
- Transducers (map, filter, take, drop, etc.)
- MarkSweep GC with free-pool recycling

### Namespaces

| Namespace        | Vars | Description                      |
| ---------------- | ---- | -------------------------------- |
| clojure.core     | 537  | Core language                    |
| clojure.string   | 21   | String manipulation              |
| clojure.math     | 44   | Math functions (java.lang.Math)  |
| clojure.set      | 12   | Set operations                   |
| clojure.walk     | 8    | Tree walking                     |
| clojure.test     | -    | Test framework                   |
| clojure.template | -    | Code templates                   |
| clojure.data     | -    | Data diff                        |
| clojure.edn      | 1    | EDN reader                       |
| clojure.repl     | 8    | doc, dir, apropos, source, pst   |
| clojure.java.io  | 7    | File I/O (Zig-native compat)     |
| cljw.http        | 6    | HTTP server/client               |
| cljw.wasm        | -    | Wasm FFI (Phase 25)              |

### Build & Distribution

- `cljw build app.clj -o app` — single binary with source bundled
- Multi-file project support with `require` resolution (depth-first)
- Zero-config project model (auto-detect `src/`, `cljw.edn` optional)
- Binary trailer format: `[cljw binary][bundled source][u64 size]["CLJW"]`
- Build-time bootstrap cache (instant startup, no runtime parsing)

### Server & Networking

- **HTTP server**: Ring-compatible handler model (`cljw.http/run-server`)
  - Thread-per-connection, background mode, live reload via nREPL
- **HTTP client**: `cljw.http/get`, `post`, `put`, `delete`
- **nREPL server**: CIDER-compatible (14 ops), `--nrepl-server --port=N`
  - Built binaries also support `--nrepl` flag for live development
- **Signal handling**: SIGINT/SIGTERM graceful shutdown with hooks
- **Shutdown hooks**: `(add-shutdown-hook! :key f)` for cleanup

### Developer Experience

- Interactive REPL with multi-line input
- nREPL + CIDER integration (eval, complete, info, stacktrace, eldoc)
- Live reload: redefine handler via nREPL, apply with `set-handler!`
- `--tree-walk` flag for reference backend comparison
- `--dump-bytecode` for VM debugging
- Error messages with source location and phase/kind classification

### Testing

- 1,175 Zig test blocks
- 54 Clojure test files (SCI + upstream ports), 218 deftests
- Dual-backend verification (VM + TreeWalk)
- 21 benchmarks across computation, collections, HOF, GC, state

## Usage

```bash
nix develop                       # dev shell (Zig 0.15.2)
zig build

# Run
./zig-out/bin/cljw -e '(+ 1 2)'            # evaluate expression
./zig-out/bin/cljw script.clj               # run file
./zig-out/bin/cljw                           # interactive REPL

# Build single binary
./zig-out/bin/cljw build app.clj -o myapp
./myapp                                      # runs without cljw

# Server mode
./zig-out/bin/cljw --nrepl-server --port=7888 app.clj

# Test & Benchmark
zig build test                               # run all tests
bash bench/run_bench.sh --release-safe       # benchmarks
```

## Quick Start: HTTP API Server

```clojure
;; app.clj
(require '[cljw.http :as http])

(defn handler [req]
  (case (:uri req)
    "/hello" {:status 200 :body "{\"msg\": \"Hello!\"}"}
    "/time"  {:status 200 :body (str (System/nanoTime))}
    {:status 404 :body "Not Found"}))

(http/run-server handler {:port 8080})
```

```bash
# Run directly
./zig-out/bin/cljw app.clj

# Or build a standalone binary
./zig-out/bin/cljw build app.clj -o myapp
./myapp                    # serves on :8080
./myapp --nrepl 7888       # serves on :8080 + nREPL on :7888
```

## Architecture

- **NaN-boxed Value** (D72) — `enum(u64)`: float pass-through, i48 integer, 40-bit heap pointer
- **MarkSweep GC** (D69) — tracks allocations in HashMap, free-pool recycling, safe points
- **Dual backend** (D6) — VM (bytecode, 50+ opcodes) + TreeWalk (AST), `EvalEngine.compare()`
- **Instantiated VM** (D3) — no threadlocal/global mutable state (Env is passed)
- **Bootstrap cache** — core.clj pre-compiled at Zig build time, restored in ~2-3ms
- **Hybrid bootstrap** (D18) — core.clj via TreeWalk, hot paths recompiled to VM bytecode

## Project Structure

```
src/
├── main.zig                        CLI entry point
├── root.zig                        Library root
├── clj/clojure/                    Clojure source files
│   ├── core.clj                    Core library (2242 lines)
│   ├── string.clj, set.clj, ...   Standard library namespaces
│
├── common/                         Shared foundation
│   ├── value.zig                   NaN-boxed Value type
│   ├── env.zig                     Environment
│   ├── gc.zig                      MarkSweep garbage collector
│   ├── lifecycle.zig               Signal handling, shutdown hooks
│   ├── bootstrap.zig               Bootstrap + eval pipelines
│   ├── serialize.zig               Bytecode serialization (AOT)
│   ├── reader/                     Tokenizer, Reader, Form
│   ├── analyzer/                   Form -> Node AST analysis
│   ├── bytecode/                   OpCode, Chunk, Compiler (50+ opcodes)
│   └── builtin/                    290 builtins across 20+ modules
│
├── native/                         Native execution track
│   ├── vm/vm.zig                   Stack-based bytecode VM
│   └── evaluator/tree_walk.zig     Direct AST interpreter
│
├── repl/                           REPL + nREPL subsystem
│   ├── nrepl.zig                   nREPL server (14 ops, CIDER-compatible)
│   └── bencode.zig                 Bencode encoder/decoder
│
├── wasm/                           Wasm FFI (Phase 25)
└── api/                            Embedding API

bench/                              21 benchmarks, 8 languages
test/                               54 Clojure test files
```

## Roadmap

Completed: Phases 1-34 (reader, VM, builtins, GC, optimization, NaN boxing, single binary, nREPL, build system, namespaces, HTTP server)

| Phase | Focus                        | Status      |
| ----- | ---------------------------- | ----------- |
| 35    | Cross-platform distribution  | Next        |
| 36    | Wasm FFI deep                | Planned     |
| 37    | Advanced GC + JIT research   | Planned     |

## License

EPL-1.0 (Eclipse Public License)
