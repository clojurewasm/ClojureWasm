# Changelog

All notable changes to ClojureWasm are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[SemVer](https://semver.org/). SemVer compatibility guarantees start at the
first stable `1.0.0` tag; pre-1.0 `alpha` / `rc` tags may still change surfaces.

## [1.1.0] - 2026-07-12

Minor release: new REPL / tooling surface and Java-interop additions, a batch
of GC-correctness fixes, and a WebAssembly engine bump. Backward-compatible
with 1.0.x.

### Added

- **`clojure.repl` bundled** — `doc`, `find-doc`, `apropos`, `dir`, `demunge`,
  plus a bare `(doc x)` at the interactive prompt (clojure.main parity).
- **`:arglists` / `:doc` metadata** on `clojure.core` and the eager standard
  library vars — CIDER eldoc now resolves argument lists and docstrings.
- **Regex lookbehind** — `(?<=…)` / `(?<!…)` and `Pattern.split`.
- **`format` date/time** — the `%t` / `%T` conversion family (UTC, English).
- **Namespace metadata** — `alter-meta!` / `reset-meta!` on namespaces, and a
  namespace docstring / attribute map merged into the namespace metadata.
- **Java-interop surface** — common `java.util.Arrays` and
  `java.util.Collections` statics, `String` `char[]` forms, and JVM-bit-parity
  Murmur3 hashing.
- **`slurp` / `spit` accept open streams** (the remaining IOFactory arms).
- **WebAssembly FFI on zwasm v2.2.0** — up from v2.0.0 (table64 JIT +
  AOT full-fidelity); hot loops inside a module keep running as native code.

### Fixed

- **GC-correctness batch** — several use-after-free / corruption classes under
  frequent collection: unrooted analysis-time constants, tree-walk
  native-stack intermediates, `recur` reentrancy inside lazy `for`, and a
  `rest`-of-chunked-seq self-allocation hole that could corrupt a growing
  BFS-style queue. All now hold their roots across the collection.
- **Value semantics** — sorted collections work as hash keys / set elements;
  hash-map full-hash collision buckets match Clojure; `count` on a
  `CharSequence` `deftype`; `(var alias/x)` resolves namespace aliases;
  `read-line` reads process stdin; exception `str` / `pr` and
  `*print-readably*` shadowing match Clojure.

## [1.0.1] - 2026-07-02

Patch release: memory-safety fixes found by a post-release audit. No API
changes. Users on 1.0.0 should upgrade — the first item is reachable from
ordinary code.

### Fixed

- **Stack overflow on deep lazy chains** — realizing or counting a lazy
  sequence / cons chain longer than ~400k elements (e.g.
  `(count (repeat 1000000 1))`) crashed the process: the GC mark phase
  descended the object graph recursively on the native stack. Marking now
  uses an explicit gray worklist (O(1) stack for any depth).
- **Use-after-free family during analysis/compilation** — GC values created
  while a form is analyzed, compiled, or AOT-deserialized (literal strings,
  quoted data, chunk constants, macro-expansion intermediates) were not GC
  roots until execution, so a collection mid-analysis (large file loads,
  user-macro expansion) could recycle them — surfacing as per-run-varying
  `Unable to resolve symbol: '<garbage>'` errors, index-out-of-bounds
  panics, or spurious "host-marker method not yet wired" errors when
  loading bigger libraries (instaparse, math.combinatorics). A per-thread
  analysis-roots frame now keeps them alive; `deftype` / `reify` method
  tables are also traced (their method functions could be collected out
  from under a live type).
- **Namespace reflection errors are now catchable** — `ns-resolve`,
  `ns-map`, `ns-name`, `intern`, `create-ns`, `alias`, `find-var` and
  friends raised an uncatchable "not supported" error on a missing
  namespace or wrong-typed argument; Clojure raises a plain catchable
  exception there, and libraries rely on that for capability probes
  (`(try (ns-resolve …) (catch Exception e nil))`). They now match
  Clojure's exception classes.

## [1.0.0] - 2026-07-01

The first **stable** release. ClojureWasm is a JVM-free Clojure runtime written
in Zig, feature-complete for everyday Clojure with a WebAssembly FFI as its
headline capability. The WebAssembly FFI runs on the embedded **zwasm v2.0.0**
engine. Earlier pre-releases were tagged `1.0.0-alpha.*`. SemVer compatibility
guarantees start here.

### Added

- **Clojure language core** — reader, macros, destructuring, the sequence
  library, transducers, protocols, multimethods, `deftype` / `reify` /
  `defrecord`, metadata, namespaces with lazy loading, and the numeric tower
  (long / double / ratio / BigInteger / BigDecimal, JVM-surface semantics).
- **Standard library** — `clojure.core` plus `clojure.string` / `set` / `walk`
  / `zip` / `edn` / `data.json` / `data.csv` / `math` / `pprint` / `test` /
  `tools.cli` and more, reimplemented for the runtime.
- **WebAssembly FFI** — `(wasm/load "mod.wasm")` then `(wasm/call m "fn" …)`:
  load a sandboxed module compiled from any language (Rust, Go, Zig, C) and
  call it like an ordinary function. The FFI is **JIT-compiled by default** via
  the embedded **zwasm v2.0.0** engine, so a hot loop inside a module runs as native code.
- **WebAssembly components as namespaces** — `(:require ["comp.wasm" :as c])`
  pulls a WIT-typed component in like a library; its exports become ordinary
  Vars, with arguments and results as plain Clojure data.
- **CIDER-compatible nREPL** — `cljw nrepl` for live editor-connected eval.
- **Single-binary builds** — `cljw build script.clj -o app` compiles a program
  and the runtime into one self-contained native executable (arm64 / amd64).
- **Concurrency** — atoms, refs (STM), agents, promises, futures.
- **Java-interop surface** — a curated, definition-derived subset of common
  `java.*` classes (String / Math / java.time / BigInteger / BigDecimal /
  Character / …) reimplemented natively; see `data/compat_tiers.yaml`.

### Notes

- Behavioural equivalence with JVM Clojure is the target on the user-observable
  surface; intentional divergences are catalogued in
  [`docs/clojure_vs_clojurewasm.md`](docs/clojure_vs_clojurewasm.md).
- Licensed under EPL-2.0; third-party components in
  [`legal/THIRD_PARTY.md`](legal/THIRD_PARTY.md).
