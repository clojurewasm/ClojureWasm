<p align="center">
  <img src="docs/assets/clojurewasm_logo.png" alt="ClojureWasm" height="160" />
  &nbsp;&nbsp;&nbsp;
  <a href="https://github.com/BuddhiLW"><img src="docs/assets/buddhilw_logo.png" alt="BuddhiLW" height="160" /></a>
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A JVM-free Clojure runtime in Zig. One 8.1 MB binary, a Wasm FFI, and a sandbox per module.</em>
</p>

<p align="center">
  <a href="https://github.com/BuddhiLW/ClojureWasm/releases/latest"><img src="https://img.shields.io/github/v/release/BuddhiLW/ClojureWasm?sort=semver&display_name=tag&label=release&color=success" alt="Latest release" /></a>
  <a href="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml"><img src="https://github.com/BuddhiLW/ClojureWasm/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/clojurewasm/homebrew-tap"><img src="https://img.shields.io/badge/brew-clojurewasm%2Ftap%2Fcljw-F9A03C?logo=homebrew&logoColor=white" alt="Homebrew tap" /></a>
  <a href="https://ziglang.org/"><img src="https://img.shields.io/badge/Zig-0.16.0-f7a41d?logo=zig&logoColor=white" alt="Zig 0.16.0" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-EPL_2.0-blue.svg" alt="License: EPL 2.0" /></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#try-it-online">Demos</a> ·
  <a href="#call-c-from-clojure">Call C from Clojure</a> ·
  <a href="#how-it-works">How it works</a> ·
  <a href="#numbers">Numbers</a> ·
  <a href="#where-it-fits">Where it fits</a> ·
  <a href="#what-runs">What runs</a> ·
  <a href="#documentation">Docs</a>
</p>

`cljw` runs Clojure without a JVM. It ships as one static binary, starts in
milliseconds, and embeds a WebAssembly engine: a `.wasm` built from C, Rust,
Go or Zig loads like a library and runs inside a sandbox whose fuel and memory
you set.

## Install

```sh
brew install clojurewasm/tap/cljw             # macOS arm64, Linux x86_64
zig build -Dwasm -Doptimize=ReleaseSafe       # or from source (Zig 0.16)
```

Prebuilt binaries are on [Releases](https://github.com/BuddhiLW/ClojureWasm/releases),
each with a `SHA256SUMS` file and a signed build attestation. To check that a
tarball was built by this repository's release workflow:

```sh
gh attestation verify cljw-linux-x86_64.tar.gz -R BuddhiLW/ClojureWasm
```

The binaries are not code-signed; on macOS, `xattr -d com.apple.quarantine "$(which cljw)"`
once.

```sh
cljw -e '(->> (range) (filter even?) (take 5))'   # (0 2 4 6 8)
cljw script.clj                                    # run a file
cljw                                               # REPL
cljw nrepl --port 7888                             # nREPL, CIDER-compatible
cljw build script.clj -o app                       # self-contained native binary
```

## Try it online

Both demos are a `cljw` server and a ClojureScript page, one container each,
tracking the latest release.

| Demo | What it shows | Source |
|---|---|---|
| [Playground](https://cljw.buddhilw.com/playground/) | Evaluate Clojure under a step, time and heap budget; call Rust and Go Wasm modules | [cw-playground](https://github.com/clojurewasm/cw-playground) |
| [Bookshelf](https://cljw.buddhilw.com/bookshelf/) | SQLite compiled to Wasm as the store, a Rust module for cover colours | [cw-serverless-demo](https://github.com/clojurewasm/cw-serverless-demo) |

## Call C from Clojure

A C function, compiled to Wasm, called with ordinary Clojure interop.

```c
// docs/examples/polyglot/c/kernel.c
EXPORT("sum_f64") double sum_f64(int off, int n) {
    const double *p = (const double *)(long)off;
    double s = 0.0;
    for (int i = 0; i < n; i++) s += p[i];
    return s;
}
```

```sh
zig cc -target wasm32-freestanding -O2 -nostdlib \
  -Wl,--no-entry -Wl,--export-memory -Wl,-z,stack-size=65536 kernel.c -o kernel.wasm
```

```clojure
(def k (wasm/load "docs/examples/polyglot/c/kernel.wasm" {:fuel 1000000 :max-memory-pages 16}))

(mapv :name (wasm/exports k))     ;=> ["memory" "buf_addr" "buf_cap" "sum_f64" "scale_f64"]

(def buf (.buf_addr k))
(wasm/mem-write! k :f64 buf [1.0 2.0 3.0 4.0])
(.sum_f64 k buf 4)                 ;=> 10.0
```

`wasm/exports` and the dot form need v1.15.1 or later; `(wasm/call k "sum_f64"
buf 4)` works on every version. A guest fault is a catchable
exception, never a host crash, and a guest that runs out of fuel stops with an
error while your process keeps going.

A WIT component goes further: it is required like a namespace, and records,
lists and `result<T, E>` cross as plain Clojure data.

```clojure
(ns my.app (:require ["./typed_payload.wasm" :as tp]))   ; Rust + wit-bindgen

(tp/process {:xs [3 4 5] :label "data"})   ;=> [:ok {:xs [3 4 5 12], :label "data!"}]
(tp/process {:xs [] :label "fail"})        ;=> [:err "boom: fail"]
```

| guest | crosses the boundary as | entry point |
|---|---|---|
| C, Zig, Rust `no_std` | scalars, arrays in guest memory | `wasm/load`, `wasm/call`, `(.f m args)`, `wasm/mem-*` |
| Rust + wit-bindgen | records, lists, strings, results | `(:require ["x.wasm" :as x])` |
| Go (`wasip1`) | argv, env, stdin, stdout, exit code | `wasm/run` |

All of them build and run in [`docs/examples/polyglot`](./docs/examples/polyglot/README.md),
rebuilt from source by CI on every push.

## How it works

```mermaid
flowchart LR
    S[".clj / .cljc / .cljw"] --> R["reader + analyzer"]
    R --> TW["tree-walk interpreter"]
    R --> VM["bytecode VM"]
    TW --> RT["runtime: NaN-boxed values, mark-sweep GC,<br/>persistent collections, STM, agents, nREPL"]
    VM --> RT
    RT --> Z["zwasm engine<br/>interpreter + JIT, fuel and memory budgets"]
    Z --> W[".wasm modules and WIT components<br/>from C, Rust, Go, Zig"]
```

Two backends evaluate the same analyzer output, and every test runs on both:
a mismatch fails the build. [`docs/architecture.md`](./docs/architecture.md)
has the map.

## Numbers

```mermaid
xychart-beta
    title "Binary size, MB (cljw 8.14 MB, others measured 2026-07-16)"
    x-axis ["cljw", "Joker", "babashka", "jank"]
    y-axis "MB" 0 --> 140
    bar [8.14, 28.8, 71.2, 129.7]
```

```mermaid
xychart-beta
    title "Process startup, ms (Apple M4 Pro, hyperfine, 2026-07-16)"
    x-axis ["Zig", "C", "Go", "cljw", "babashka", "Python", "Java", "Ruby", "Node", "Clojure JVM"]
    y-axis "ms" 0 --> 240
    bar [1.4, 3.2, 3.2, 10.0, 13.6, 18.8, 28.0, 33.7, 46.4, 231.9]
```

- Persistent collections trade wins with JVM Clojure op by op: map `assoc`
  3.9× faster, vector `conj` 4.4× slower ([measured](./docs/works/collection_performance.md)).
- Tight numeric loops are the JVM's: about 45 ns per empty iteration here
  against 2 ns under its JIT. Put a hot kernel in a Wasm guest.
- In a guest, the engine runs 2× to 3× behind wasmtime, and one call costs
  about 1 µs ([bench](./bench/README.md)).

The release size is checked against the built binary on every push.

## Where it fits

- **Untrusted code in-process.** Plugins, MCP tool servers, handlers that run
  user code: a module sees only what you pass it, under a fuel and memory budget.
- **Other languages' libraries.** Reach Rust, C, Go or Zig code through Wasm
  instead of a JVM.
- **Existing native tools.** `clojure.java.shell/sh` runs a binary by argv and
  returns `{:exit :out :err}`, as on the JVM and babashka.
- **Short-lived processes.** CLIs, scripts and serverless handlers that pay
  for startup thousands of times a day.
- **One program, two runtimes.** A host-free `.cljc` runs unchanged on the
  JVM, on `cljw` and on its Rust-hosted sibling
  [clojurust](https://github.com/BuddhiLW/clojurust) (`cljrs`).

```mermaid
flowchart LR
    P["demo.cljc<br/>one Clojure program"] --> A["cljw<br/>Wasm component, zero imports"]
    P --> B["cljrs<br/>native cdylib"]
    A --> L[("arkworks Groth16<br/>the same Rust crate")]
    B --> L
```

| Groth16 over BN254, same crate | cljrs (native) | cljw (Wasm) |
|---|---|---|
| proof, verify | 128 bytes, true / false | 128 bytes, true / false |
| wall time | 1.29 s (debug build) | 9.17 s |
| env vars / file read / clock | 212 / granted / granted | 0 / denied / trap |

Confinement or speed, chosen per deployment, without a rewrite.

## What runs

`clojure.core` and the everyday library (`string`, `set`, `walk`, `zip`,
`edn`, `data.json`, `data.csv`, `pprint`, `test`, `spec`, `tools.cli` and more),
STM, agents, futures, real threads, transducers, protocols, records,
multimethods, `deftype` / `reify` and the full numeric tower. `deps.edn` with
`:local/root`, `:git` and `:mvn/version` coordinates; libraries such as malli,
hiccup, honeysql and test.check load today ([ladder](./docs/works/ladder.md)).

Not yet: `core.async`, `java.time.format`, and a strict `clojure.edn` reader.
JVM-only interop (`gen-class`, `proxy` over arbitrary classes, reflection) is
out of scope by design. Details:
[`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md).

## Documentation

[`docs/`](./docs/README.md) ·
[CHANGELOG](./CHANGELOG.md) ·
[vs JVM Clojure](./docs/clojure_vs_clojurewasm.md) ·
[landscape](./docs/landscape.md) ·
[testing](./docs/testing.md) ·
[demos](./docs/works/demos.md) ·
[roadmap](./.dev/ROADMAP.md)

Issues and PRs are welcome at
[BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm/issues); the most
useful report is Clojure code that behaves differently here than on the JVM.

## License and credit

Eclipse Public License 2.0 ([LICENSE](./LICENSE), [NOTICE](./legal/NOTICE)).

Created by [Shota Kudo (@chaploud)](https://github.com/chaploud), who built it
from nothing to a working JVM-free Clojure with a Wasm FFI through v1.10.1. In
2026-10 the project passed to [@BuddhiLW](https://github.com/BuddhiLW); the
fork's work (v1.11 to v1.15.0) is merged back into
[clojurewasm/ClojureWasm](https://github.com/clojurewasm/ClojureWasm). Releases
are cut on [BuddhiLW/ClojureWasm](https://github.com/BuddhiLW/ClojureWasm) and
again when they reach clojurewasm/ClojureWasm; each repository bumps its own
owner's Homebrew tap from its own build. The engine is
[zwasm](https://github.com/zwasm/zwasm).
