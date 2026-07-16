# Binary size — where cljw sits among comparable runtimes

cljw ships as **one static binary** (no JVM, no install tree, no side files
— ADR-0158). This page places that binary among other language runtimes and
Wasm engines, using **measured** numbers, and states the method so the
comparison stays honest. The internal size budget + reduction levers live in
`.dev/decisions/0172_binary_size_budget_and_ledger.md`; this page is the
user-facing view.

**Method.** Each ranked runtime was downloaded from its latest official
release as of **2026-07-16**, extracted, and its executable measured with
`stat` — exact bytes, uncompressed, macOS arm64 assets wherever offered
(exceptions noted). Multi-file distributions record both the main binary and
the extracted total. Entries marked *published figure* were not re-measured
locally. cljw's own number is the shipped brew artifact.

## Among Clojure implementations

| Runtime  | Version         | Binary                                    | Notes                                            |
|----------|-----------------|-------------------------------------------|--------------------------------------------------|
| **cljw** | v1.3.1          | **9,469,816 B (9.5 MB)**                  | single static binary, Wasm JIT engine included   |
| Joker    | v1.9.0          | 28,784,146 B (28.8 MB)                    | Go interpreter; Clojure dialect                  |
| babashka | v1.12.218       | 71,181,856 B (71.2 MB)                    | GraalVM native image                             |
| jank     | 2025-01 nightly | 129,697,904 B main binary (196.9 MB tree) | Linux x86_64 prerelease only; dynamically linked |
| planck   | 2.28.0          | (no release binary)                       | links the OS JavaScriptCore framework            |

cljw is currently the **smallest standalone Clojure-family runtime binary**
measured.

## Among general "batteries-included" runtimes

| Runtime                     | Version         | Binary                                        | Capability class                |
|-----------------------------|-----------------|-----------------------------------------------|---------------------------------|
| Lua                         | 5.4             | ~0.3 MB *(published figure)*                  | minimal embeddable, tiny stdlib |
| Janet                       | v1.41.2         | 876,680 B (0.9 MB)                            | Lisp, small stdlib              |
| LuaJIT                      | 2.1             | ~1.1 MB (bin + dylib)                         | JIT Lua                         |
| QuickJS-ng                  | v0.15.1         | 1,124,864 B (1.1 MB, arm64 slice)             | ES2023 JavaScript               |
| Chez Scheme                 | —              | ~2.7 MB *(published figure)*                  | native-compiling Scheme         |
| Cyber                       | 2024-11 rolling | 2,945,224 B (2.9 MB)                          | new scripting language (Zig)    |
| wazero (CLI)                | v1.12.0         | 5,518,546 B (5.5 MB)                          | Wasm runtime alone, Go          |
| GraalVM native-image        | CE 25.1.3       | ~6.5 MB *(published, Java HelloWorld, Linux)* | floor for ONE compiled app      |
| luvi (luvit)                | v2.15.0         | 7,178,136 B (7.2 MB)                          | Lua + libuv                     |
| **cljw**                    | v1.3.1          | **9,469,816 B (9.5 MB)**                      | full Clojure + Wasm JIT engine  |
| extism CLI                  | v1.6.3          | 15,813,954 B (15.8 MB)                        | Wasm plugin framework           |
| Python (portable, stripped) | 3.14.6          | 18.1 MB binary + 66.2 MB tree                 | not single-file                 |
| SBCL                        | —              | ~45 MB core *(published; ~12 MB compressed)*  | Common Lisp                     |
| wasmtime (CLI)              | v46.0.1         | 51,475,600 B (51.5 MB)                        | Wasm runtime alone              |
| Bun                         | v1.3.14         | 63,096,576 B (63.1 MB)                        | JS all-in-one                   |
| Node.js                     | v26.3.0         | ~71.3 MB (runtime dylib)                      | JS                              |
| Deno                        | v2.9.3          | 82,681,952 B (82.7 MB)                        | JS/TS all-in-one                |
| wasmer (CLI)                | v7.2.0          | 174,242,656 B (174.2 MB)                      | Wasm runtime alone              |
| WasmEdge                    | 0.17.1          | ~175.9 MB (runtime dylib)                     | Wasm runtime alone              |

## Reading the table

Sizes cluster into three capability layers:

1. **~0.3-3 MB — embeddable minimalists** (Lua, Janet, QuickJS, Cyber).
   Small standard libraries, no compatibility target with an existing
   ecosystem. A different class of tool, listed for scale.
2. **~5-20 MB — full runtimes as one binary.** The realistic floor for
   "a complete language + its stdlib in a single file": GraalVM's compiled
   HelloWorld floor (~6.5 MB) and wazero (a Wasm engine alone, 5.5 MB) bound
   it from below. cljw's 9.5 MB sits here — carrying both a Clojure runtime
   *and* an embedded JIT-compiling Wasm engine (for scale: wasmtime, a Wasm
   engine alone, is 51.5 MB).
3. **50-180 MB — the modern batteries-included mainstream** (Node, Deno,
   Bun, babashka, wasmtime, wasmer). This is the industry's actual
   center of gravity today.

## Caveats

- Reference platform is macOS arm64; Linux x86_64 artifacts differ slightly
  (cljw's Linux binary is within ~10%). jank had no macOS/stable release, so
  its number is the Linux prerelease.
- "Capability class" comparisons are indicative, not equivalences — a JS
  runtime, a Wasm engine, and a Clojure runtime do different jobs. The
  honest claims are the two above: smallest Clojure-family binary, and a
  full-runtime-plus-Wasm-engine inside the 5-20 MB single-binary layer.
- cljw's number will move: the tracked reduction levers (unwind-table strip,
  embedded-data compression) project **~7.6-7.8 MB**; feature growth pushes
  the other way. The README figure is gate-checked against every release
  build, so it cannot silently rot.
