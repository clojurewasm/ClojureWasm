# Differences from Clojure JVM

This document lists known differences between ClojureWasm and reference
Clojure (JVM). ClojureWasm targets behavioral compatibility but diverges
where JVM-specific features have no meaningful equivalent.

## Execution Model

### Concurrency

ClojureWasm supports multi-threaded concurrency via Zig's thread pool:

| Feature         | Status          | Notes                              |
|-----------------|-----------------|------------------------------------|
| atom, volatile  | Implemented     | Thread-safe (atomic operations)    |
| future, promise | Implemented     | Zig std.Thread based               |
| pmap, pcalls    | Implemented     | Chunked parallel dispatch          |
| agent, send     | Implemented     | Per-agent serial queue             |
| ref, dosync     | Not implemented | STM out of scope (atom suffices)   |

### No Java Interop

ClojureWasm has no JVM and cannot call Java classes. The following are
permanently excluded:

- `.` (dot operator), `..`, `new`, `memfn`
- `reify`, `proxy`, `gen-class`, `gen-interface`, `definterface`
- `import`, `bean`, `class?`, `supers`, `bases`
- `monitor-enter`, `monitor-exit`

Java standard library functionality is replaced with Zig equivalents:

| Java Pattern                 | ClojureWasm Equivalent    |
|------------------------------|---------------------------|
| `(System/nanoTime)`          | `(__nano-time)`           |
| `(System/currentTimeMillis)` | `(__current-time-millis)` |
| `(System/getenv "KEY")`      | `(__getenv "KEY")`        |
| `(System/exit 0)`            | `(__exit 0)`              |
| `(Math/sqrt x)`              | `(__sqrt x)`              |
| `(Thread/sleep ms)`          | `(__sleep ms)`            |
| `(.getMessage e)`            | `(ex-message e)`          |

## Namespaces

### Not Implemented (JVM-only)

| Namespace                | Reason                               |
|--------------------------|--------------------------------------|
| clojure.reflect          | JVM reflection                       |
| clojure.inspector        | JVM Swing UI                         |
| clojure.java.javadoc     | JVM-specific                         |
| clojure.test.junit       | JUnit integration                    |

### Partially Implemented

| Namespace             | Done | Total | Notes                       |
|-----------------------|------|-------|-----------------------------|
| clojure.core          | 651  | 706   | 92% — see skip list below   |
| clojure.core.protocols| 10   | 11    | CollReduce, IKVReduce       |
| clojure.core.server   | 7    | 11    | No socket REPL              |
| clojure.instant       | 3    | 5     | No Calendar/Timestamp       |
| clojure.java.process  | 5    | 9     | No async process            |
| clojure.main          | 16   | 20    | REPL, script loading        |
| clojure.repl          | 11   | 13    | No Java reflection          |
| clojure.test          | 38   | 39    | No spec integration         |
| clojure.xml           | 7    | 9     | Pure Clojure parser         |

### Fully Implemented

clojure.core.reducers (22), clojure.core.specs.alpha (1),
clojure.data (5), clojure.datafy (2), clojure.edn (2),
clojure.java.browse (2), clojure.java.io (19), clojure.java.shell (5),
clojure.math (45), clojure.pprint (26), clojure.repl.deps (3),
clojure.set (12), clojure.spec.alpha (87), clojure.spec.gen.alpha (54),
clojure.stacktrace (6), clojure.string (21), clojure.template (2),
clojure.test.tap (7), clojure.walk (10), clojure.zip (28),
cljw.wasm (17), cljw.http (6).

## Skipped clojure.core Vars (55 of 706)

### JVM Class System (~25 vars)

`compile`, `*compile-path*`, `*compile-files*`, `gen-class`, `gen-interface`,
`definterface`, `proxy`, `proxy-super`, `init-proxy`, `get-proxy-class`,
`construct-proxy`, `reify`, `memfn`, `bean`, `supers`, `bases`, `class?`,
`accessor`, `create-struct`, `defstruct`, `struct`, `struct-map`

### STM/Refs (~10 vars)

`ref`, `alter`, `commute`, `ref-set`, `dosync`, `ensure`,
`ref-history-count`, `ref-min-history`, `ref-max-history`

### Threading/Locking (~5 vars)

`monitor-enter`, `monitor-exit`, `locking`, `add-classpath`,
`with-loading-context`

### Java Interop (~10 vars)

`import`, `import*`, `.`, `..`, `new`, `iterator-seq`, `enumeration-seq`,
`resultset-seq`, `vector-of`

### I/O Types (~5 vars)

`input-stream`, `output-stream`, `reader`, `writer`, `as-url`

## Behavioral Differences

### Numeric Model

- **Unified integers**: ClojureWasm uses a single integer type (i48 in NaN
  box, overflow to BigInt). JVM Clojure distinguishes Long, Integer, Short,
  Byte. `(instance? Long x)` should be replaced with `(integer? x)`.
- **Unified floats**: `double?` and `float?` are equivalent (all floats are
  f64). JVM distinguishes Float and Double.
- **BigInt/BigDecimal/Ratio**: Implemented with pure Zig (not java.math).
  Functionally compatible but internal representation differs.

### Macros and Special Forms

- **`case`**: Implemented as `cond` chain (O(n) linear scan). JVM Clojure
  compiles `case` to a O(1) hash dispatch via the `case*` special form.
- **`defn`**: No `:inline` function support. Attribute map handling simplified.
- **`ns`**: No `:gen-class` support.
- **`extend-type`**: Special form, not a macro (no runtime expansion).

### Sequences and Reducibles

- **`eduction`**: Returns an eager sequence. JVM Clojure returns an Eduction
  object implementing IReduceInit for lazy transducer application.
- **`iteration`**: Returns a lazy-seq. JVM Clojure returns a reified
  Seqable + IReduceInit.
- **`reduce-kv`**: Falls back to map entry sequence iteration. JVM Clojure
  uses the IKVReduce protocol for direct key-value reduction.
- **`nthnext`/`nthrest`**: Loop-based. JVM Clojure uses the IDrop interface
  for O(1) dropping on supported collections.

### Test Framework (clojure.test)

- **`*report-counters*`**: Uses atom (not ref + dosync).
- **`report`**: Dynamic function (not multimethod).
- **`thrown?`**: Standalone macro. JVM Clojure dispatches through the
  `assert-expr` multimethod inside `is`.
- **`deftest`**: Registers in an atom-based registry (not ns metadata).

### Other

- **`clojure.pprint/pprint`**: Zig builtin implementation. Simplified
  compared to JVM's dispatch-based pretty printer.
- **`clojure.java.shell/sh`**: Uses Zig `std.process.Child` (not
  `Runtime.exec()`). Functionally equivalent.
- **`clojure.stacktrace`**: Adapted for ClojureWasm's error model (no Java
  Throwable / StackTraceElement).
- **`clojure.walk`**: No IMapEntry / IRecord protocol checks.
- **`clojure.data`**: Type checks instead of protocol dispatch.
- **Regex**: Built-in engine (not `java.util.regex`). Core operations
  (`re-find`, `re-matches`, `re-seq`, `re-groups`) are compatible.

## Exception Handling

ClojureWasm supports exception type checking in catch clauses.
`Exception`, `Throwable`, and `RuntimeException` catch all thrown values.
Specific exception types (e.g., `ExceptionInfo`) are matched by the
`__ex_type` field on exception maps.

```clojure
;; Both work:
(try (/ 1 0) (catch Exception e (ex-message e)))
(try (throw (ex-info "oops" {:k 1}))
     (catch ExceptionInfo e (ex-data e)))
```

JVM Clojure's deep class hierarchy (ArithmeticException, ClassCastException,
etc.) is not replicated; use `Exception` for general catches.

`ex-info`, `ex-message`, `ex-data`, and `ex-cause` work as expected.

## Platform

- **Verified**: macOS Apple Silicon (aarch64-macos), Linux x86_64
- **Cross-compiles**: Linux aarch64, macOS x86_64
- **Not tested**: Windows, other architectures
- **ARM64 JIT**: Only active on aarch64; no-op on other architectures
