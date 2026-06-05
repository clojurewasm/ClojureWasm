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
| **ReleaseSafe** — recommended release build | **2.24 MB** (2,351,488 bytes) |
| ReleaseSmall — optimised for size           | 1.09 MB (1,146,032 bytes)     |
| ReleaseFast — optimised for speed           | 2.26 MB (2,367,856 bytes)     |

Measured with Zig 0.16.0 for `aarch64-macos`. **ReleaseSafe is the recommended
release build** (optimised *with* runtime safety checks), so 2.24 MB is the
honest "what you download" number; a size-optimised ReleaseSmall build comes in
at about half that. Sizes are for the default `cljw` (the optional WebAssembly
FFI engine is behind `-Dwasm`).

What sits inside that binary: a full Clojure numeric tower (Long→BigInt
promotion, Ratio, BigDecimal), MVCC software transactional memory, agents,
futures/promises/delays, lazy + chunked sequences, transducers,
protocols/records/multimethods, namespaces, a CIDER-compatible nREPL, and ~10
`clojure.*` standard namespaces — plus both a tree-walking interpreter and a
bytecode VM.

## Cold start (secondary, machine-dependent)

End-to-end `cljw -e nil` (process spawn + runtime init + eval), measured on the
ReleaseSafe build with [`hyperfine`](https://github.com/sharkdp/hyperfine) `-N`
on an Apple M4 Pro:

```
≈ 4–5 ms (mean), warm filesystem cache
```

This includes loading the AOT-compiled `clojure.core` bootstrap (ADR-0056), so
it is the real time-to-first-eval a user experiences. It is not a stable
cross-machine number — reproduce it on your own hardware with the script above.

## Honesty note

These figures supersede earlier rougher estimates (~600 KB / ~2.5 ms). The
binary grew as the numeric tower, STM, agents, nREPL, and protocols landed;
~2.2 MB (ReleaseSafe) is the honest current size for the full runtime, ~1.1 MB
if built purely for size. The point is not a size record — it is that a
from-scratch Clojure runtime with this much of the language ships as a single
small binary that starts in a few milliseconds.
