<p align="center">
  <img src="assets/clojurewasm_logo.png" alt="ClojureWasm" width="180" />
</p>

<h1 align="center">ClojureWasm</h1>

<p align="center">
  <em>A from-scratch Clojure runtime in Zig — no JVM, WebAssembly at the core.</em>
</p>

> [!NOTE]
> ClojureWasm is **not yet stable** and is built by a very small team with
> limited resources. To keep that focus, **Issues and Pull Requests are not
> being accepted** right now. You are very welcome to read along, try it, and
> say hello in [GitHub Discussions](https://github.com/clojurewasm/ClojureWasm/discussions).

## What it is

ClojureWasm is a ground-up implementation of Clojure written in Zig 0.16. It
runs as a small native binary with no JVM, embeds a WebAssembly engine so
Clojure can call modules compiled from other languages, and is designed to
compile to WebAssembly itself.

## Features

- **A real numeric tower** — `Long`→`BigInt` promotion, `Ratio`, `BigDecimal`.
- **Software transactional memory** — `ref` / `dosync` / `alter` / `commute` / `ensure`.
- **Concurrency** — `agent`, `future` / `promise` / `delay`, `atom`, reference watches.
- **Lazy and chunked sequences**, transducers.
- **Protocols, records, multimethods**, `deftype` / `reify`.
- **Namespaces** and a **CIDER-compatible nREPL**, plus a growing set of
  `clojure.*` standard-library namespaces.
- **WebAssembly as an FFI** — load a sandboxed module compiled from Rust / Zig /
  C and call it like a namespace.
- **A dual backend** — every end-to-end test runs on both a tree-walking
  interpreter and a bytecode VM in lockstep; a disagreement fails the build.

## Quickstart

Build it (needs Zig 0.16 — `direnv allow` loads it via Nix, or `nix develop`):

```sh
zig build
alias cljw=./zig-out/bin/cljw
```

Then:

```sh
# Exact rational arithmetic — a real Ratio, not a float
cljw -e '(/ 1 3)'                                  ;=> 1/3

# Arbitrary-precision integers
cljw -e '(* (bigint 1000000000000) 1000000000000)' ;=> 1000000000000000000000000N

# Software transactional memory
cljw -e '(let [a (ref 0)] (dosync (alter a + 41) (alter a inc)) @a)'  ;=> 42

# A REPL (and an nREPL via `cljw nrepl` for CIDER)
cljw
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

- [`ARCHITECTURE.md`](./ARCHITECTURE.md) — a 5-minute orientation (zones, dual
  backend, error system, compatibility tiers).
- [`docs/clojure_vs_clojurewasm.md`](./docs/clojure_vs_clojurewasm.md) —
  intentional divergences from JVM Clojure and the not-yet-implemented surface.
- [`compat_tiers.yaml`](./compat_tiers.yaml) — the tiered JVM-compatibility
  ledger.

## License

Eclipse Public License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
EPL-2.0 follows the Clojure ecosystem convention (Clojure, Babashka, and SCI use
EPL-1.0; newer projects such as Malli use EPL-2.0).
