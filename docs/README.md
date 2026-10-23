# ClojureWasm documentation

Start here. Everything in this directory is versioned with the code it
describes, so a document that is wrong is a diff someone can fix in the same PR
as the behaviour — which is why these live in the repository rather than in a
GitHub wiki.

## If you are…

**…using cljw**

- [`clojure_vs_clojurewasm.md`](./clojure_vs_clojurewasm.md) — what matches JVM
  Clojure, what deliberately diverges, and what is not there yet. Read this
  first when something behaves unexpectedly; the answer is often a listed,
  intentional difference.
- [`../README.md`](../README.md) — install, quickstart, the Wasm FFI.
- [`examples/polyglot/`](./examples/polyglot/README.md) — C, Zig, Rust and Go
  guests through the FFI, each with its build line, and one `.cljc` that runs
  on `cljw`, `cljrs` and the JVM. Run it before writing your own guest.
- [`examples/ffi/`](./examples/ffi/README.md): `cljw.ffi`, calling a native
  shared library (C, Go c-shared, Rust cdylib, Zig) directly, with the hive C
  ABI as the worked example.
- [`examples/zig-native/`](./examples/zig-native/README.md): one Zig source
  (comptime tables, `@Vector` SIMD, bit builtins, `std.crypto`) called as a
  wasm guest and as a native library, with the per-call costs of each route.
- [`works/ladder.md`](./works/ladder.md) — which real-world Clojure libraries
  load and run today.

**…contributing a patch**

- [`testing.md`](./testing.md) — **read before sending a patch.** How to run the
  suite, what each of the eight test layers is for, how to read each layer's
  failures, and where a new test belongs.
- [`../.github/CONTRIBUTING.md`](../.github/CONTRIBUTING.md) — what helps a PR
  land, and the list of this repository's own conventions that explicitly do
  **not** apply to outside contributions.
- [`architecture.md`](./architecture.md) — a short orientation to how the
  runtime is put together, for when a fix needs to know where it is.

**…deciding whether to depend on it**

- [`landscape.md`](./landscape.md) — where cljw sits among Clojure runtimes,
  and how it pairs with its Rust-hosted sibling `cljrs`.
- [`works/binary_size.md`](./works/binary_size.md) — the measured size
  comparison behind the headline number.
- [`works/collection_performance.md`](./works/collection_performance.md) — cljw
  against JVM Clojure on the persistent data structures, measured: where it is
  faster, where it is slower, and the one operation still to fix.
- [`../CHANGELOG.md`](../CHANGELOG.md) — release history; the SSOT for what
  changed when.

**…debugging something specific**

- [`spec/error_format.md`](./spec/error_format.md) — the error rendering
  contract (the source excerpt, the caret, the trace).
- [`spec/formats/`](./spec/formats) — on-disk and wire formats.
- [`examples/`](./examples) — runnable examples, including the `.wasm` modules
  the docs and tests call.

## Where the rest of it lives

Not everything is in `docs/`, and the split is deliberate:

| You want | Look in |
|---|---|
| Why a design is the way it is | Commit messages cite `ADR-NNNN`; the ADR record itself is kept in the maintainer's knowledge base, not in the tree |
| Which invariants are law | `.dev/project_facts.md` — the `F-NNN` facts every other document aligns to |
| What is known-broken or deferred | `.dev/debt.yaml` — the debt ledger, with a testable barrier per row |
| What a divergence from JVM Clojure costs and why it was accepted | `.dev/accepted_divergences.yaml` |
| What a gate script checks | The script's own header in `scripts/` — each is its own SSOT |
| What the test suite covers | [`testing.md`](./testing.md) and `test/README.md` |
| Release history | `CHANGELOG.md` |

`docs/ja/` holds Japanese-language material from the project's original
maintainer. `docs/research/` holds background surveys that informed decisions
but are not themselves decisions.
