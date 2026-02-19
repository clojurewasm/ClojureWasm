# Spec Differences from JVM Clojure

ClojureWasm aims for behavioral compatibility with JVM Clojure 1.12.
This document lists concrete behavioral differences.

## Architecture

| Aspect | JVM Clojure | CW |
|--------|-------------|-----|
| Runtime | JVM (HotSpot) | Native (Zig 0.15.2) |
| Compilation | Bytecode → JIT | Custom bytecode → VM |
| GC | JVM GC (G1/ZGC) | Mark-and-sweep |
| Concurrency | Threads + STM | Single-threaded |
| Numbers | long/double/BigInteger/BigDecimal | i64/f64 (no BigInteger/BigDecimal) |
| Strings | Java String (UTF-16) | Zig []const u8 (UTF-8) |
| Regex | java.util.regex | PCRE-compatible (Zig) |
| I/O | java.io streams | Zig std.fs + POSIX |

## Semantic Differences

### Numbers

- No BigInteger or BigDecimal. All integers are 64-bit signed.
- Integer overflow wraps (no automatic promotion to BigInteger).
- `with-precision` is a stub (binds `*math-context*` but has no effect).
- `rationalize` returns the float unchanged (no Ratio type).

### Concurrency

- `locking` is a no-op (single-threaded, no Java monitors).
- `send-via`, `set-agent-send-executor!`, `set-agent-send-off-executor!` are skipped.
- Agents work but execute synchronously (same thread).
- STM (`ref`, `dosync`, `alter`, `commute`) works but is not truly transactional.
- `future` runs synchronously (returns a completed deref-able value).
- `pmap` falls back to `map` (no parallel execution).

### Types and Protocols

- `deftype` is skipped. `defrecord` covers data use cases.
- `class?` always returns false (no Java class system).
- `type` returns a keyword (`:long`, `:double`, `:string`, etc.) not a Java class.
- `instance?` uses CW's type keyword system, not Java class hierarchy.
- `reader-conditional` and `tagged-literal` return maps, not their JVM types.
- `reader-conditional?` and `tagged-literal?` check map shape, not type.

### I/O

- `line-seq` takes a filename string, not a BufferedReader.
- `reader` / `make-reader` slurps a file into a PushbackReader.
- `writer` / `make-writer` creates a BufferedWriter with buffer-and-flush.
- `input-stream` / `output-stream` delegate to reader/writer.
- `as-url` returns a URI, not a java.net.URL.
- Stream types (`*in*`, `*out*`, `*err*`) are nil by default (not JVM streams).

### Structs

- `create-struct`, `struct`, `struct-map`, `accessor`, `defstruct` use plain maps.
- Functionally equivalent but without JVM's StructMap optimizations.

### Reducers

- `fold` runs sequentially (no ForkJoin parallelism).
- `fjtask` is identity (no ForkJoinTask).
- `pool` is nil (no ForkJoinPool).

### Other

- `eduction` returns an eager sequence wrapper (no IReduceInit).
- `sequence` with transducers is eager via `into` (no TransformerIterator).
- `iteration` uses lazy-seq wrapper (no IReduceInit protocol).
- `demunge` is identity (CW doesn't munge names).
- `source-fn` uses paren-counting instead of reader-based parsing.
- `with-open` uses `(close x)` instead of `(.close x)`.
- `definline` does not set `:inline` metadata.
- `defn` does not support `:inline` or `:arglists` metadata.

## Namespaces Not Implemented

| Namespace | Reason |
|-----------|--------|
| `clojure.inspector` | Requires Java Swing |
| `clojure.reflect` | Requires JVM reflection API |
| `clojure.java.javadoc` | Javadoc URL browser |

## CW-Specific Features

| Feature | Namespace | Description |
|---------|-----------|-------------|
| Wasm FFI | `cljw.wasm` | Load and call WebAssembly modules |
| HTTP client | `cljw.http` | Native HTTP client |
| `cljw build` | CLI | Build standalone single-binary executables |
| `cljw test` | CLI | Built-in test runner |
| nREPL server | CLI | `--nrepl-server` flag |

## Reader Differences

- Reader conditionals: `:cljw` feature (in addition to `:clj`, `:cljs`).
- Reader conditional priority: `:cljw` > `:clj` > `:default`.
- No Java class literals in reader.
