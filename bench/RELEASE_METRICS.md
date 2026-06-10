# Release metrics

The number ClojureWasm locks as its headline is **binary size**, because it is
*reproducible*: given a Zig version and target, anyone re-running the build gets
the same bytes. Cold start is reported too, but as a secondary,
machine-dependent figure (it varies with CPU and filesystem cache).

Reproduce both:

```sh
bash bench/release_metrics.sh
```

## Locked figure

| Build (default `cljw`, no `-Dwasm`)          | Size (stripped)               |
|----------------------------------------------|-------------------------------|
| **ReleaseSafe** — recommended release build | **3.39 MB** (3,557,216 bytes) |
| ReleaseSmall — optimised for size           | 1.63 MB (1,707,888 bytes)     |

Measured with Zig 0.16.0 for `aarch64-macos` (2026-06-10). **ReleaseSafe is the
recommended release build** (optimised *with* runtime safety checks), so 3.39 MB
is the honest "what you download" number; a size-optimised ReleaseSmall build is
about half that. Sizes are for the default `cljw`; with the optional WebAssembly
FFI engine (`-Dwasm`) the ReleaseSafe build is about **3.80 MB** (still a single
binary, around 4 MB).

What sits inside that binary: a full Clojure numeric tower (Long→BigInt
promotion, Ratio, BigDecimal), MVCC software transactional memory, agents,
futures/promises/delays, lazy + chunked sequences, transducers,
protocols/records/multimethods, namespaces, a CIDER-compatible nREPL, and ~24
bundled `clojure.*` standard namespaces — plus both a tree-walking interpreter
and a bytecode VM.

## Cold start (secondary, machine-dependent)

End-to-end `cljw -e nil` (process spawn + runtime init + eval), measured on the
ReleaseSafe build with [`hyperfine`](https://github.com/sharkdp/hyperfine) `-N`
on an Apple M4 Pro (re-measured 2026-06-11):

```
≈ 5 ms (4.8 ms ± 0.2 mean), warm filesystem cache
```

This includes loading the AOT-compiled `clojure.core` bootstrap (ADR-0056), so
it is the real time-to-first-eval a user experiences. It is not a stable
cross-machine number — reproduce it on your own hardware with the script above.

## Honesty note

These figures supersede earlier rougher estimates (~600 KB / ~2.5 ms). The
binary grew as the numeric tower, STM, agents, nREPL, protocols, and the bundled
`clojure.*` namespaces landed; ~3.4 MB (ReleaseSafe) is the honest current size
for the full runtime, ~1.6 MB if built purely for size. The point is not a size
record — it is that a from-scratch Clojure runtime with this much of the
language ships as a single small binary that starts in a few milliseconds.
