# Differences from Clojure JVM

This document lists known differences between ClojureWasm and reference
Clojure (JVM). ClojureWasm targets behavioral compatibility but diverges
where JVM-specific features have no meaningful equivalent.

## Execution Model

### Single-threaded

ClojureWasm runs in a single thread. Concurrency primitives that require
threading are not yet implemented:

| Feature         | Status          | Notes                              |
|-----------------|-----------------|------------------------------------|
| atom, volatile  | Implemented     | Work as expected (single-threaded) |
| future, promise | Not implemented | Planned for a future release       |
| pmap, pcalls    | Not implemented | Planned with future                |
| agent, send     | Not implemented | Requires multi-thread GC safety    |
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

### Not Implemented

| Namespace                | Reason                               |
|--------------------------|--------------------------------------|
| clojure.spec.alpha       | Complexity; out of scope for alpha   |
| clojure.spec.gen.alpha   | Depends on spec                      |
| clojure.core.specs.alpha | Depends on spec                      |
| clojure.core.reducers    | Requires reify + ForkJoin            |
| clojure.core.server      | Socket REPL (nREPL used instead)     |
| clojure.reflect          | JVM reflection                       |
| clojure.inspector        | JVM Swing UI                         |
| clojure.java.browse      | JVM Desktop class                    |
| clojure.java.javadoc     | JVM-specific                         |
| clojure.main             | JVM entry point                      |
| clojure.instant          | JVM Date/Timestamp                   |
| clojure.datafy           | Requires protocols not yet available |

### Partially Implemented

| Namespace      | Done | Total | Notes                       |
|----------------|------|-------|-----------------------------|
| clojure.core   | 593  | 706   | 84% — see skip list below   |
| clojure.test   | 32   | 39    | No spec integration         |
| clojure.pprint | 9    | 26    | Core pprint + print-table   |
| clojure.repl   | 11   | 13    | No spec, no Java reflection |
| clojure.edn    | 1    | 2     | read-string only (no read)  |
| clojure.data   | 3    | 5     | No protocol-based dispatch  |

### Fully Implemented

clojure.string (21), clojure.set (12), clojure.math (45), clojure.walk (10),
clojure.zip (28), clojure.template (2), clojure.stacktrace (6),
clojure.java.io (7), clojure.java.shell (5), cljw.http (6).

## Skipped clojure.core Vars (112 of 706)

### JVM Class System (~25 vars)

`compile`, `*compile-path*`, `*compile-files*`, `gen-class`, `gen-interface`,
`definterface`, `proxy`, `proxy-super`, `init-proxy`, `get-proxy-class`,
`construct-proxy`, `reify`, `memfn`, `bean`, `supers`, `bases`, `class?`,
`accessor`, `create-struct`, `defstruct`, `struct`, `struct-map`

### Concurrency (~35 vars)

**Agents**: `agent`, `send`, `send-off`, `send-via`, `await`, `await-for`,
`agent-error`, `agent-errors`, `restart-agent`, `set-agent-send-executor!`,
`set-agent-send-off-executor!`, `release-pending-sends`, `*agent*`,
`set-error-handler!`, `error-handler`, `set-error-mode!`, `error-mode`

**STM/Refs**: `ref`, `alter`, `commute`, `ref-set`, `dosync`, `ensure`,
`io!`, `ref-history-count`, `ref-min-history`, `ref-max-history`

**Futures**: `future`, `future-call`, `future-cancel`, `future-cancelled?`,
`future-done?`, `future?`, `pmap`, `pcalls`, `pvalues`, `seque`

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

ClojureWasm has a single `Exception` type. JVM Clojure's exception class
hierarchy (ArithmeticException, ClassCastException, etc.) is collapsed:

```clojure
;; JVM Clojure
(try (/ 1 0) (catch ArithmeticException e ...))

;; ClojureWasm — use Exception for all
(try (/ 1 0) (catch Exception e ...))
```

`ex-info`, `ex-message`, `ex-data`, and `ex-cause` work as expected.

## Platform

- **Verified**: macOS Apple Silicon (aarch64-macos)
- **CI passes**: Linux x86_64, Linux aarch64
- **Not tested**: Windows, other architectures
- **ARM64 JIT**: Only active on aarch64; no-op on other architectures
