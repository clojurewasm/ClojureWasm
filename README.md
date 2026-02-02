# ClojureWasm

Clojure runtime written from scratch in Zig. Behavioral compatibility with Clojure JVM (black-box).

## Features

- Full Clojure reader (literals, reader macros, syntax-quote, regex)
- Dual backend: TreeWalk (reference) + bytecode VM (54x faster on fib)
- 211 vars implemented (core.clj bootstrap: 663 lines)
- Interactive REPL with multi-line input
- nREPL server (CIDER-compatible)
- Wasm target (wasm32-wasi, 207KB)
- 748 tests, 11 benchmarks across 8 languages

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
│   └── core.clj                    Clojure bootstrap (defn, macros, HOFs)
│
├── common/                         Shared foundation
│   ├── value.zig                   Value tagged union (18 variants)
│   ├── env.zig                     Environment (instantiated, no threadlocal)
│   ├── namespace.zig               Namespace (intern/find/refer)
│   ├── var.zig                     Var (root + dynamic bindings)
│   ├── collections.zig             PersistentList/Vector/ArrayMap/HashSet
│   ├── bootstrap.zig               core.clj loading + evalString pipelines
│   ├── eval_engine.zig             Dual-backend compare mode
│   ├── error.zig                   ErrorContext
│   ├── gc.zig                      GC strategy trait (arena stub)
│   ├── macro.zig                   Macro expansion
│   ├── reader/
│   │   ├── tokenizer.zig           Lexer
│   │   ├── reader.zig              Parser (read-time macro expansion)
│   │   └── form.zig                Form type (Value + source location)
│   ├── analyzer/
│   │   ├── analyzer.zig            Form → Node (special forms, var resolution)
│   │   └── node.zig                AST node types (14 variants)
│   ├── bytecode/
│   │   ├── opcodes.zig             OpCode enum
│   │   ├── chunk.zig               Chunk, FnProto, instruction encoding
│   │   └── compiler.zig            Node → Bytecode
│   └── builtin/
│       ├── registry.zig            BuiltinDef registration
│       ├── arithmetic.zig          +, -, *, /, mod, rem, comparisons
│       ├── collections.zig         first, rest, conj, assoc, get, nth, count, ...
│       ├── sequences.zig           map, filter, reduce, sort, range, ...
│       ├── predicates.zig          nil?, number?, empty?, instance?, ...
│       ├── strings.zig             str, subs, name, namespace, ...
│       ├── numeric.zig             abs, max, min, rand, bit-ops, ...
│       ├── io.zig                  println, prn, pr-str, slurp, spit
│       ├── atom.zig                atom, deref, swap!, reset!
│       └── special_forms.zig       Special form dispatch table
│
├── native/                         Native execution track
│   ├── vm/
│   │   └── vm.zig                  Stack-based bytecode VM
│   └── evaluator/
│       └── tree_walk.zig           Direct AST interpreter
│
├── repl/                           REPL subsystem
│   ├── nrepl.zig                   nREPL server (TCP, bencode)
│   └── bencode.zig                 Bencode encoder/decoder
│
├── wasm_rt/                        Wasm runtime track (placeholder)
│   ├── vm/
│   └── gc/
│
├── wasm/                           Wasm FFI (placeholder)
└── api/                            Embedding API (placeholder)

bench/                              Benchmark suite (11 benchmarks, 8 languages)
.dev/                               Development plans, status tracking, notes
```

## Architecture

- **Tagged union Value** — 18 variants, NaN boxing deferred
- **Arena allocator** — bulk free, real GC deferred
- **Dual backend** — VM (default, fast) + TreeWalk (reference, correct)
- **Instantiated VM** — no threadlocal/global mutable state
- **core.clj bootstrap** — read+eval at startup (AOT embed deferred)

## License

TBD
