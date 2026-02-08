# Namespace Audit — Phase 33.1

Date: 2026-02-08
Scope: Compare CW namespaces with JVM Clojure and Babashka.

## 1. Current ClojureWasm Namespaces

| #  | Namespace         | Impl       | vars.yaml  | Notes                              |
|----|-------------------|------------|------------|------------------------------------|
| 1  | clojure.core      | Zig + .clj | 535/704    | Main language core                 |
| 2  | clojure.string    | Zig        | 21/21      | Complete                           |
| 3  | clojure.edn       | Zig        | 1/2*       | read-string done, read missing     |
| 4  | clojure.math      | Zig        | 0/45*      | Builtins exist, vars.yaml unmarked |
| 5  | clojure.walk      | .clj       | 8/10       | Near complete                      |
| 6  | clojure.template  | .clj       | 2/2        | Complete                           |
| 7  | clojure.test      | .clj       | 14/39      | Core test framework works          |
| 8  | clojure.set       | .clj       | 12/12      | Complete                           |
| 9  | clojure.data      | .clj       | 3/5        | diff works                         |
| 10 | clojure.repl      | .clj*      | 8/8        | Functions in core.clj, NOT in separate ns |
| 11 | wasm              | Zig        | N/A        | CW-specific: load, fn, memory-*   |
| 12 | user              | (auto)     | N/A        | Startup ns, refers clojure.core    |

*clojure.edn: read-string builtin exists but vars.yaml shows todo.
*clojure.math: PI, E, sqrt, sin etc. registered as builtins, vars.yaml shows 0/45.
*clojure.repl: doc/dir/apropos/find-doc/source/pst defined in core.clj, not a separate namespace.

**Total: 10 functional namespaces + user + wasm**

## 2. JVM Clojure Standard Namespaces (~46)

### Core
- clojure.core
- clojure.core.protocols
- clojure.core.reducers
- clojure.core.server

### Data/Collections
- clojure.data, clojure.set, clojure.walk, clojure.zip
- clojure.instant, clojure.uuid

### String/IO
- clojure.string, clojure.edn
- clojure.java.io, clojure.java.shell, clojure.java.process
- clojure.java.browse, clojure.java.javadoc
- clojure.xml, clojure.datafy

### Pretty Printing
- clojure.pprint (+ 7 sub-namespaces)

### Testing/REPL
- clojure.test (+ junit, tap)
- clojure.repl, clojure.repl.deps

### Compilation/Meta
- clojure.template, clojure.main, clojure.stacktrace
- clojure.genclass, clojure.reflect

### Math
- clojure.math

## 3. Babashka Namespaces (Key Subset)

### Clojure compat layer (what BB provides)
- clojure.core, clojure.string, clojure.set, clojure.walk, clojure.data
- clojure.edn, clojure.math, clojure.test, clojure.template
- clojure.java.io, clojure.java.shell, clojure.java.browse, clojure.java.process
- clojure.pprint, clojure.stacktrace, clojure.main, clojure.zip
- clojure.repl, clojure.instant
- clojure.core.async, clojure.core.protocols
- clojure.spec.alpha, clojure.spec.gen.alpha, clojure.spec.test.alpha
- clojure.tools.cli, clojure.tools.reader
- clojure.data.csv

### Babashka extensions (babashka.* prefix)
- babashka.core, babashka.curl, babashka.deps
- babashka.fs, babashka.pods, babashka.process
- babashka.terminal, babashka.nrepl, babashka.wait

### Pattern
- `clojure.*` = JVM compatibility (same API, different backend)
- `babashka.*` = Babashka-unique extensions
- `clojure.java.*` = Reimplemented with native ops (no actual Java)

## 4. Gap Analysis

### A. CW has, JVM has — DONE (10)

| CW Namespace      | JVM Equivalent     | Status    |
|--------------------|--------------------|-----------|
| clojure.core       | clojure.core       | 535/704   |
| clojure.string     | clojure.string     | Complete  |
| clojure.edn        | clojure.edn        | Partial   |
| clojure.math       | clojure.math       | Builtins exist, yaml stale |
| clojure.walk       | clojure.walk       | 8/10      |
| clojure.template   | clojure.template   | Complete  |
| clojure.test       | clojure.test       | 14/39     |
| clojure.set        | clojure.set        | Complete  |
| clojure.data       | clojure.data       | 3/5       |
| clojure.repl       | clojure.repl       | 8/8 (in core.clj, no separate ns) |

### B. CW has, JVM doesn't — CW-SPECIFIC (1)

| CW Namespace | Purpose              | Recommendation        |
|-------------|----------------------|------------------------|
| wasm        | Wasm FFI             | Rename to `cljw.wasm`  |

### C. JVM has, CW missing — GAPS (by priority)

#### Tier 1: High Priority (Babashka has, commonly used in scripts)

| Namespace           | JVM vars | BB has? | CW state                  | Action                  |
|---------------------|----------|---------|---------------------------|-------------------------|
| clojure.java.io     | 19       | Yes     | slurp/spit in core        | Add compat ns (33.3)    |
| clojure.java.shell  | 5        | Yes     | Not implemented           | Add sh function (33.4)  |
| clojure.pprint      | 26       | Yes     | Not implemented           | Implement (future)      |
| clojure.stacktrace  | 6        | Yes     | pst in core.clj           | Add compat ns           |
| clojure.main        | 20       | Yes     | Not implemented           | Partial (repl, main)    |

#### Tier 2: Medium Priority (useful but less critical)

| Namespace               | JVM vars | BB has? | Action                       |
|-------------------------|----------|---------|------------------------------|
| clojure.zip             | 28       | Yes     | Pure Clojure, port upstream  |
| clojure.instant         | 5        | Yes     | Date/time parsing            |
| clojure.uuid            | N/A      | Partial | UUID generation              |
| clojure.core.protocols  | small    | Yes     | IKVReduce etc.               |

#### Tier 3: Low Priority (JVM-specific or niche)

| Namespace              | Reason to defer                   |
|------------------------|-----------------------------------|
| clojure.reflect        | JVM reflection API                |
| clojure.java.javadoc   | JVM-only                          |
| clojure.java.browse    | Desktop-only (open URL)           |
| clojure.java.process   | Clojure 1.11+, BB has alt         |
| clojure.inspector      | GUI/Swing-based                   |
| clojure.genclass       | JVM compilation                   |
| clojure.xml            | XML parsing (need native lib)     |
| clojure.datafy         | nav/datafy protocol               |
| clojure.test.junit     | JUnit integration                 |
| clojure.test.tap       | TAP output                        |
| clojure.core.reducers  | Parallel fold (needs threading)   |
| clojure.core.server    | Socket REPL server                |
| clojure.spec.alpha     | Spec system (large surface)       |
| clojure.parallel       | Deprecated                        |

## 5. Naming Issues

### Issue 1: `wasm` namespace has no prefix
- JVM Clojure: all namespaces are `clojure.*`
- Babashka: extensions use `babashka.*` prefix
- CW: `wasm` is a bare name — collision risk, non-standard
- **Recommendation**: Rename to `cljw.wasm`

### Issue 2: clojure.repl not a real namespace
- Functions (doc, dir, apropos, etc.) are defined in core.clj
- JVM has them in a separate `clojure.repl` namespace
- User code `(require '[clojure.repl :refer [doc]])` would fail
- **Recommendation**: Extract to separate clojure.repl ns (33.2)

### Issue 3: clojure.java.io compat
- `slurp` and `spit` already in clojure.core (correct per JVM)
- But `clojure.java.io` provides: reader, writer, file, copy, delete-file,
  make-parents, as-file, as-url, resource, input-stream, output-stream
- Scripts commonly do `(require '[clojure.java.io :as io])`
- **Recommendation**: Create compat layer with Zig native I/O (33.3)

### Issue 4: vars.yaml staleness
- clojure.math: builtins registered, vars.yaml shows 0 done
- clojure.edn: read-string builtin exists, vars.yaml shows todo
- **Recommendation**: Audit and fix vars.yaml in 33.1

## 6. Recommendations for 33.2 (Design Decision)

### Namespace Naming Convention (D## decision)

1. **`clojure.*`**: Standard JVM Clojure namespaces — same API for portability
   - clojure.core, clojure.string, clojure.set, clojure.walk, etc.
   - clojure.java.io, clojure.java.shell — compat layer (native impl)

2. **`cljw.*`**: ClojureWasm-unique extensions
   - cljw.wasm (was: wasm) — Wasm FFI
   - cljw.build (future) — build system API
   - cljw.native (future) — native FFI, system access

3. **User namespace**: `user` (default, same as JVM)

### Priority Implementation Order

Phase 33:
1. Extract clojure.repl to separate namespace
2. Rename wasm → cljw.wasm
3. Add clojure.java.io compat layer
4. Add System interop routing (System/getenv etc.)
5. Fix vars.yaml staleness

Future phases:
- clojure.pprint (large, but important for REPL UX)
- clojure.java.shell (sh function)
- clojure.zip (pure Clojure port)
- clojure.stacktrace
- clojure.main (partial)
