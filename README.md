<p align="center">
  <img src="assets/clojurewasm_logo.png" alt="ClojureWasm" width="180" />
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A JVM-free Clojure runtime in Zig, with a WebAssembly FFI.</em>
</p>

> [!NOTE]
> ClojureWasm is **not yet stable** and is built by a very small team with
> limited resources. To keep that focus, **Issues and Pull Requests are not
> being accepted** right now. You are very welcome to read along, try it, and
> say hello in [GitHub Discussions](https://github.com/clojurewasm/ClojureWasm/discussions).

## What it is

ClojureWasm is a Clojure runtime written from scratch in Zig and Clojure, with
no JVM. It builds to a small native binary (arm64 / amd64) that starts in
milliseconds. Its main feature is a **WebAssembly FFI**: from your Clojure code
you can load a module compiled from another language — Rust, Go, Zig, C — and
call it like an ordinary function. The idea is to stay in the Clojure world and
still use what other languages have already built.

## Features

- **Small and quick to start** — about 3.8 MB, starting in ~5 ms, which suits
  short-lived, start-and-stop workloads (CLI tools, serverless, scripts).
- **A lot of everyday Clojure runs** — `clojure.core` plus a growing set of
  standard-library namespaces (`clojure.string` / `set` / `walk` / `zip` /
  `edn` / `data.json` / `data.csv` / `math` / `pprint` / `test` / `tools.cli` …).
- **A CIDER-compatible nREPL** — `cljw nrepl` and connect your editor to
  evaluate real Clojure live.
- **WebAssembly as an FFI** — `(wasm/load "mod.wasm")` then
  `(wasm/call m "fn" …)`: a sandboxed module from any language, called like a
  namespace.
- **Single-binary builds** — `cljw build script.clj -o app` compiles your
  program (and the runtime) into one self-contained executable.

## Quickstart

Build the optimized, Wasm-enabled binary (needs Zig 0.16 — `direnv allow` loads
it via Nix, or `nix develop`):

```sh
zig build -Dwasm -Doptimize=ReleaseSafe   # → ./zig-out/bin/cljw
```

Then (the examples assume `cljw` is on your `PATH`):

```sh
# Call a WebAssembly module compiled from another language, like a function
cljw -e '(wasm/call (wasm/load "examples/wasm/add.wasm") "add" 40 2)'   ;=> 42

# Evaluate an expression
cljw -e '(->> (range) (filter even?) (take 5))'     ;=> (0 2 4 6 8)

# Run a file
cljw script.clj

# A REPL — and an nREPL for CIDER / your editor
cljw
cljw nrepl --port 7888

# Compile a program to a single self-contained native binary
cljw build script.clj -o app
```

## Try it live

- **Playground** — <https://cw-playground.fly.dev> — run Clojure in your browser,
  evaluated in-process by `cljw`; call sandboxed Rust / Go WebAssembly modules
  over the FFI. ([source](https://github.com/clojurewasm/cw-playground))
- **Bookshelf demo** — <https://cw-serverless-demo.fly.dev> — a small multi-user
  bookshelf served end-to-end by `cljw`'s own HTTP server, with SQLite and
  book-cover colours running in-process through the WebAssembly FFI, no JVM.
  ([source](https://github.com/clojurewasm/cw-serverless-demo))

## Documentation

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — a short orientation to how the runtime
  is put together.
- [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md) — what
  matches JVM Clojure, the intentional divergences, and what is not yet there.
- [`bench/README.md`](./bench/README.md) — the benchmark catalogue and
  cross-language cold-start numbers.

## License

Eclipse Public License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
