# Release metrics

The one number ClojureWasm locks as its headline is **binary size**, because it
is *reproducible*: given a Zig version and target, anyone re-running the build
gets the same bytes. Cold start is reported too, but as a secondary,
machine-dependent figure (it varies with CPU and filesystem cache).

Reproduce both:

```sh
bash bench/release_metrics.sh
```

## Locked figure

| Metric                                   | Value                         |
|------------------------------------------|-------------------------------|
| **Binary size** (ReleaseSmall, stripped) | **1.09 MB** (1,146,032 bytes) |
| Binary size (ReleaseSmall, on disk)      | 1.21 MB (1,268,744 bytes)     |
| Binary size (ReleaseFast, stripped)      | 2.26 MB (2,367,856 bytes)     |

Measured with Zig 0.16.0 for `aarch64-macos`. The build is the default `cljw`
(no optional WebAssembly FFI engine; that is behind `-Dwasm`).

What sits inside that 1.09 MB: a full Clojure numeric tower (Long→BigInt
promotion, Ratio, BigDecimal), MVCC software transactional memory, agents,
futures/promises/delays, lazy + chunked sequences, transducers,
protocols/records/multimethods, namespaces, a CIDER-compatible nREPL, and ~10
`clojure.*` standard namespaces — plus both a tree-walking interpreter and a
bytecode VM.

## Cold start (secondary, machine-dependent)

End-to-end `cljw -e nil` (process spawn + runtime init + eval), measured with
[`hyperfine`](https://github.com/sharkdp/hyperfine) `-N` on an Apple M4 Pro:

```
≈ 5 ms (mean), warm filesystem cache
```

This includes loading the AOT-compiled `clojure.core` bootstrap (ADR-0056), so
it is the real time-to-first-eval a user experiences. It is not a stable
cross-machine number — reproduce it on your own hardware with the script above.

## Honesty note

These figures supersede earlier rougher estimates. The binary grew as the
numeric tower, STM, agents, nREPL, and protocols landed; ~1.1 MB is the honest
current floor for the full runtime. The point is not a size record — it is that
a from-scratch Clojure runtime with this much of the language is small enough to
ship as a single ~1 MB binary that starts in a few milliseconds.
