# Compatibility Matrix

ClojureWasm (CW) targets behavioral compatibility with JVM Clojure 1.12.
This document lists namespace coverage and known differences.

## Summary

| Metric | Count |
|--------|-------|
| Total vars tracked | 1,243 |
| Implemented (done) | 1,130 (90.9%) |
| Skipped (JVM-only) | 113 (9.1%) |
| Stubs (defined, limited) | 27 |

## Namespace Coverage

| Namespace | Done | Skip | Coverage | Notes |
|-----------|------|------|----------|-------|
| `clojure.core` | 651 | 55 | 92.2% | Core language |
| `clojure.core.protocols` | 10 | 1 | 90.9% | |
| `clojure.core.reducers` | 22 | 0 | 100% | |
| `clojure.core.server` | 7 | 4 | 63.6% | No socket REPL |
| `clojure.core.specs.alpha` | 1 | 0 | 100% | |
| `clojure.data` | 5 | 0 | 100% | |
| `clojure.datafy` | 2 | 0 | 100% | |
| `clojure.edn` | 2 | 0 | 100% | |
| `clojure.inspector` | 0 | 13 | 0% | Swing GUI — N/A |
| `clojure.instant` | 3 | 2 | 60% | No Calendar/Timestamp |
| `clojure.java.browse` | 2 | 0 | 100% | |
| `clojure.java.io` | 19 | 0 | 100% | |
| `clojure.java.javadoc` | 0 | 8 | 0% | Javadoc browser — N/A |
| `clojure.java.shell` | 5 | 0 | 100% | |
| `clojure.java.process` | 5 | 4 | 55.6% | No async process |
| `clojure.main` | 16 | 4 | 80% | |
| `clojure.math` | 45 | 0 | 100% | |
| `clojure.pprint` | 26 | 0 | 100% | Full cl-format |
| `clojure.reflect` | 0 | 17 | 0% | Java reflection — N/A |
| `clojure.repl` | 11 | 2 | 84.6% | |
| `clojure.repl.deps` | 3 | 0 | 100% | Stubs only |
| `clojure.set` | 12 | 0 | 100% | |
| `clojure.spec.alpha` | 87 | 0 | 100% | |
| `clojure.spec.gen.alpha` | 54 | 0 | 100% | |
| `clojure.stacktrace` | 6 | 0 | 100% | |
| `clojure.string` | 21 | 0 | 100% | |
| `clojure.template` | 2 | 0 | 100% | |
| `clojure.test` | 38 | 1 | 97.4% | |
| `clojure.test.tap` | 7 | 0 | 100% | |
| `clojure.walk` | 10 | 0 | 100% | |
| `clojure.xml` | 7 | 2 | 77.8% | Pure Clojure parser |
| `clojure.zip` | 28 | 0 | 100% | |

### CW-Specific Namespaces

| Namespace | Vars | Notes |
|-----------|------|-------|
| `cljw.wasm` | 17 | Wasm FFI (unique to CW) |
| `cljw.http` | 6 | HTTP client |

## Skipped Vars by Category

### JVM Interop (92 vars)

Pure Java interop that has no equivalent in a native runtime:
proxy, gen-class, gen-interface, deftype, definterface, import,
bean, bases, supers, compile, memfn, and related proxy-* vars.

### JVM Type System (8 vars)

Java-specific types: `->ArrayChunk`, `->Eduction`, `->Vec`,
`->VecNode`, `->VecSeq`, `EMPTY-NODE`, `vector-of`, `deftype*`.

### Swing GUI — clojure.inspector (13 vars)

All vars in `clojure.inspector` require Java Swing. Not applicable.

### Java Reflection — clojure.reflect (17 vars)

All vars in `clojure.reflect` require JVM reflection API. Not applicable.

### Javadoc Browser — clojure.java.javadoc (8 vars)

Javadoc URL lookup. Not applicable.

### Other (5 vars)

- `monitor-enter`, `monitor-exit`: JVM-level concurrency primitives
- `send-via`, `set-agent-send-executor!`, `set-agent-send-off-executor!`: custom ExecutorService
- `load-reader`: needs JVM Reader type

## Stubs (27 vars)

Vars that are defined but have limited or no-op behavior:

| Var | Behavior |
|-----|----------|
| `*agent*`, `*allow-unresolved-vars*`, `*compile-path*` | Bound to nil/false |
| `*e`, `*err*`, `*in*`, `*out*` | Bound to nil (no JVM streams) |
| `*fn-loader*`, `*reader-resolver*`, `*suppress-read*` | Bound to nil/false |
| `*math-context*`, `*use-context-classloader*` | Bound to nil/true |
| `*print-dup*`, `*warn-on-reflection*` | Bound to false |
| `with-precision` | Binds `*math-context*` only |
| `pprint-tab` | No-op (upstream also throws) |
| `io-prepl`, `prepl`, `remote-prepl`, `start-server` | Throw "not yet implemented" |
| `inst-in`, `inst-in-range?` | No inst types |
| `for-all*`, `quick-check` | Need test.check |
| `add-libs`, `add-lib`, `sync-deps` | Throw "not yet implemented" |

## Upstream Test Coverage

68 upstream test files, all passing.
83 Clojure test namespaces total (68 upstream + 15 CW-specific).
146 differential test expressions (CW vs JVM), all passing.
6 core e2e tests, 14 deps.edn e2e tests.

## Library Compatibility

Tested as-is (no forking). CW gets fixed when tests fail.
Full results: `test/compat/RESULTS.md`.

| Library           | Version | Type         | Pass Rate | Notes |
|-------------------|---------|--------------|-----------|-------|
| medley            | 1.8.0+  | Utility      | 82.5%     | Java interop methods are all failures |
| camel-snake-kebab | 0.12.0+ | Case convert | 98.6%     | 2 fails = split edge case |
| honeysql          | 2.6.x   | SQL DSL      | Load OK   | All 3 namespaces load |
| data.csv          | 1.1.x   | CSV I/O      | 100%      | Full read/write working |
| tools.cli         | -       | CLI parsing  | 4/6 tests | 2 pass, 3 partial, 1 crash |
| clojure.walk      | (core)  | Tree walking | 100%      | Core namespace |
| clojure.set       | (core)  | Set algebra  | 100%      | Core namespace |
| clojure.edn       | (core)  | EDN reader   | 100%      | Core namespace |
| clojure.pprint    | (core)  | Pretty print | 100%      | Full cl-format |
| clojure.xml       | (core)  | XML parser   | 100%      | Pure Clojure |

### Out of Scope (deftype dependency)

| Library     | Blocker |
|-------------|---------|
| data.json   | definterface + deftype |
| instaparse  | deftype (GLL data structures) |
| core.match  | deftype + clojure.lang internals |
| malli       | deftype in regex impl |
| meander     | &form macro binding + case* |

### Key Findings

1. Pure Clojure/cljc libraries work well (82-100%)
2. Java interop methods are the primary failure cause
3. `deftype` blocks most advanced libraries
4. Core namespaces (walk, set, edn, pprint, xml) all pass 100%
