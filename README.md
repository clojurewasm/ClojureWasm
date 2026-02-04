# ClojureWasm

Clojure runtime written from scratch in Zig. Behavioral compatibility with Clojure JVM (black-box).

## Features

- Full Clojure reader (literals, reader macros, syntax-quote, regex)
- Dual backend: TreeWalk (reference) + bytecode VM (9x faster on fib)
- 405/712 clojure.core vars implemented (57%)
- 5 Clojure namespaces (core, string, set, walk, test)
- Interactive REPL with multi-line input
- nREPL server (CIDER-compatible)
- Wasm target (wasm32-wasi, 207KB)
- 385 deftests, 1490 assertions across 22 test files, 11 benchmarks

## Usage

```bash
nix develop                       # dev shell (Zig 0.15.2 + tools)
zig build

./zig-out/bin/cljw -e '(+ 1 2)'  # evaluate expression
./zig-out/bin/cljw script.clj     # run file
./zig-out/bin/cljw                # REPL
./zig-out/bin/cljw --tree-walk    # use TreeWalk backend
./zig-out/bin/cljw --nrepl-server --port=7888  # nREPL

zig build test                    # run all tests
zig build wasm                    # build wasm target
```

## Project Structure

```
src/
├── main.zig                        CLI entry point
├── root.zig                        Library root
├── clj/
│   └── clojure/
│       ├── core.clj                Clojure core (1330 lines)
│       ├── string.clj              clojure.string
│       ├── set.clj                 clojure.set
│       ├── walk.clj                clojure.walk
│       └── test.clj                clojure.test
│
├── common/                         Shared foundation
│   ├── value.zig                   Value tagged union (24 variants)
│   ├── env.zig                     Environment (instantiated, no threadlocal)
│   ├── namespace.zig               Namespace (intern/find/refer)
│   ├── var.zig                     Var (root + dynamic bindings)
│   ├── collections.zig             PersistentList/Vector/ArrayMap/HashSet
│   ├── bootstrap.zig               core.clj loading + evalString pipelines
│   ├── eval_engine.zig             Dual-backend compare mode
│   ├── reader/                     Tokenizer, Reader, Form
│   ├── analyzer/                   Form → Node AST analysis
│   ├── bytecode/                   OpCode enum, Chunk, Compiler (49 opcodes)
│   └── builtin/                    19 builtin modules (210+ builtins)
│
├── native/                         Native execution track
│   ├── vm/vm.zig                   Stack-based bytecode VM
│   └── evaluator/tree_walk.zig     Direct AST interpreter
│
├── repl/                           REPL + nREPL subsystem
│   ├── nrepl.zig                   nREPL server (TCP, bencode)
│   └── bencode.zig                 Bencode encoder/decoder
│
├── wasm_rt/                        Wasm runtime track (stub)
├── wasm/                           Wasm FFI (stub)
└── api/                            Embedding API (stub)

bench/                              Benchmark suite (11 benchmarks, 8 languages)
test/                               22 Clojure test files (SCI + upstream ports)
```

## Architecture

- **Tagged union Value** — 24 variants, NaN boxing deferred
- **Arena allocator** — bulk free, real GC deferred
- **Dual backend** — VM (default, fast) + TreeWalk (reference, correct)
- **Instantiated VM** — no threadlocal/global mutable state
- **core.clj bootstrap** — read+eval at startup (AOT embed deferred)
- **49 opcodes** — bytecode compiler with direct-threaded VM

## License

TBD
