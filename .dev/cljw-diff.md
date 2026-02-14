# CLJW / UPSTREAM-DIFF Marker Audit

Last verified: 2026-02-14

Total: 87 markers in `src/clj/` (CLJW=56, UPSTREAM-DIFF=31)
Categories: P=48 (permanent), S=12 (syntax/bootstrap), R=27 (reducible)

## UPSTREAM-DIFF Markers (31)

Marks where CW intentionally diverges from upstream Clojure behavior or API shape.

### core.clj (18)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   45 |  R  | No :inline or :arglists metadata support                   |
|  246 |  P  | No :gen-class (JVM only)                                   |
|  278 |  P  | import registers class short names as symbol vars          |
| 1030 |  R  | Fallback for seq map entries (no seqkvreduce)              |
| 1440 |  P  | java.lang classes defined as symbols (JVM auto-imports)    |
| 1617 |  P  | double? equiv to float? (CW uses f64 for all floats)      |
| 1620 |  P  | NaN? pure Clojure (no Double/isNaN)                        |
| 1623 |  P  | infinite? pure Clojure (no Double/isInfinite)              |
| 1626 |  P  | Explicit type check (no ^String type hint)                 |
| 1640 |  R  | nthnext: no IDrop interface, uses loop                     |
| 1647 |  R  | nthrest: no IDrop interface, uses loop                     |
| 1853 |  R  | into simplified from coll-reduce to plain reduce           |
| 1951 |  R  | eduction returns eager sequence (no deftype+IReduceInit)   |
| 1959 |  R  | iteration returns lazy-seq (no reify Seqable+IReduceInit)  |
| 2329 |  P  | class? always returns false (no Java class system)         |
| 2335 |  R  | definline creates fn without :inline metadata              |
| 2477 |  S  | extend-type is special form, not macro                     |
| 2523 |  P  | reduce1->reduce, Java interop->CW equivalents              |

### test.clj (10)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    3 |  R  | Atom-based counters instead of ref-based report-counters   |
|    4 |  R  | report is a dynamic fn (not multimethod)                   |
|    5 |  P  | do-report no file/line (no StackTraceElement)              |
|    6 |  R  | deftest uses register-test atom (not ns metadata)          |
|   19 |  R  | *report-counters* aliases atom-based counters              |
|   22 |  R  | Not a ref, just returns current atom snapshot              |
|   69 |  R  | inc-report-counter uses atoms instead of dosync/commute    |
|  132 |  P  | do-report no file/line (no StackTraceElement)              |
|  318 |  R  | thrown? standalone macro (upstream uses assert-expr in is)  |
|  418 |  P  | run-test is fn (upstream macro; resolve works at runtime)  |

### spec/alpha.clj (2)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|  140 |  P  | fn-sym always returns nil (no class name decompilation)    |
|  802 |  P  | tagged-ret returns vector instead of MapEntry              |

### walk.clj (2)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   15 |  P  | No IMapEntry branch (CW map entries are plain vectors)     |
|   18 |  P  | Skip :__reify_type entry (CW record implementation detail) |

### stacktrace.clj (1)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    2 |  P  | Simplified for CW error model (no Throwable/StackTrace)    |

### repl.clj (1)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    5 |  P  | No spec support, no Java interop (LineNumberReader etc)    |

### data.clj (1)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    2 |  P  | Uses type checks instead of protocols (no Java types)      |

### pprint.clj (1)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    2 |  P  | pprint is Zig builtin, cl-format not implemented           |

### java/shell.clj (1)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    2 |  P  | sh is Zig builtin (std.process.Child), not Runtime.exec()  |

## CLJW Markers (56)

Marks CW-specific implementation details, workarounds, and Java->Zig adaptations.

### spec/alpha.clj (36)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   24 |  P  | *warn-on-reflection* not applicable                        |
|   76 |  P  | ex-info instead of IllegalArgumentException                |
|   82 |  P  | satisfies? Spec instead of instance? Spec class            |
|   91 |  P  | meta-obj? helper replaces instance? IObj                   |
|  100 |  P  | meta-obj? instead of instance? IObj                        |
|  110 |  P  | meta-obj? instead of instance? IObj                        |
|  133 |  P  | ex-info instead of IllegalArgumentException                |
|  138 |  P  | fn-sym: no JVM class name decompilation                    |
|  315 |  P  | var->symbol adaptation via meta                            |
|  334 |  P  | ^:skip-wiki removed (defn no name metadata)                |
|  353 |  P  | (ns-name *ns*) instead of (.name *ns*)                     |
|  405 |  P  | ex-info instead of IllegalArgumentException                |
|  448 |  P  | ex-info instead of UnsupportedOperationException           |
|  485 |  P  | random-uuid instead of java.util.UUID/randomUUID           |
|  601 |  S  | Explicit symbol literals instead of syntax-quote           |
|  800 |  P  | tagged-ret uses vector (no MapEntry constructor)           |
|  828 |  P  | random-uuid instead of UUID/randomUUID                     |
|  890 |  S  | Explicit 'or symbol (excluded from core, misresolves)      |
|  968 |  S  | Explicit 'and symbol (excluded from core)                  |
| 1007 |  S  | Explicit 'merge symbol (excluded from core)                |
| 1014 |  S  | k-gen checks plain symbols 'or/'and in key forms           |
| 1108 |  P  | random-uuid instead of UUID/randomUUID                     |
| 1183 |  S  | Explicit 'keys symbol (excluded from core)                 |
| 1319 |  P  | Long/MAX_VALUE instead of Integer/MAX_VALUE                |
| 1493 |  P  | Long/MAX_VALUE instead of Integer/MAX_VALUE                |
| 1597 |  P  | fspec: conform only checks ifn? (no gen-based testing)     |
| 1638 |  P  | multi-spec-impl adapted for CW defmulti                    |
| 1645 |  P  | Access multimethod internals via CW's defmulti             |
| 1689 |  P  | *compile-asserts* always true (no system properties)       |
| 1692 |  P  | Runtime assert check flag via atom (no RT.checkSpecAsserts)|
| 1739 |  S  | Explicit ~'clojure.spec.alpha/and qualification            |
| 1743 |  P  | double-in uses CW's double? and math predicates            |
| 1749 |  S  | Explicit ~'clojure.spec.alpha/and qualification            |
| 1756 |  P  | inst-in stub (no java.util.Date)                           |
| 1760 |  P  | inst types not available                                   |
| 1767 |  P  | inst types not available                                   |

### reducers.clj (14)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    9 |  S  | ns form handled by bootstrap                               |
|   14 |  S  | Alias core manually (shadows some names)                   |
|   17 |  P  | ForkJoin replaced with sequential execution                |
|   20 |  P  | No ForkJoinPool                                            |
|   22 |  P  | fjtask identity (no ForkJoinTask)                          |
|   24 |  P  | fjinvoke sequential (no ForkJoin)                          |
|   26 |  P  | fjfork no-op (sequential)                                  |
|   28 |  P  | fjjoin sequential (just calls task)                        |
|  229 |  R  | defrecord instead of deftype (deftype is skip)             |
|  230 |  R  | Counted/Seqable replaced with protocol implementations     |
|  234 |  R  | Extend Cat with CollReduce/CollFold via extend-type        |
|  260 |  P  | Vector instead of ArrayList                                |
|  274 |  P  | conj instead of .add on ArrayList                          |
|  312 |  S  | Vector fold uses foldvec for divide-and-conquer            |

### core.clj (13)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|  200 |  S  | Upstream throws IAE for odd cond forms                     |
|  202 |  S  | (second) not yet available at bootstrap time               |
|  661 |  P  | Simplified assert-args (no &form, no IllegalArgumentExc)   |
| 1252 |  S  | cond instead of condp (condp defined after case)           |
| 1791 |  P  | push/pop-input-source builtins (no Java StringReader)      |
| 1802 |  P  | *math-context* stub (no BigDecimal)                        |
| 1815 |  P  | .close interop replaced with (close x) function call       |
| 1945 |  R  | sequence uses eager into (no TransformerIterator)           |
| 2036 |  S  | __zig-lazy-map for fused reduce optimization               |
| 2276 |  P  | create-local-var builtin (no Var.create/setDynamic)        |
| 2296 |  P  | __var-bind-root builtin (no .bindRoot interop)             |
| 2395 |  P  | io! is just do (no STM LockingTransaction check)           |
| 2491 |  -  | RESOLVED: def docstring works, marker removed              |

### repl.clj (11)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    3 |  -  | (header: marker count)                                     |
|    4 |  S  | Extracted from core.clj (Phase 33.2, D82)                  |
|   67 |  R  | Simplified print-doc (no spec support)                     |
|   83 |  S  | Always emit runtime code (macro_eval_env may lag)          |
|  113 |  P  | (= :regex (type x)) instead of instance? Pattern           |
|  129 |  S  | vec around vals for sort-by compatibility                  |
|  146 |  P  | source-fn reads from filesystem (no classloader)           |
|  186 |  P  | demunge is identity (no JVM name munging)                  |
|  194 |  P  | Simplified root-cause (walks ex-cause chain)               |
|  204 |  P  | Throwable->map trace format (no StackTraceElement)         |
|  213 |  P  | pst uses Zig error stack (no Throwable)                    |

### protocols.clj (8)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    9 |  S  | ns form handled by bootstrap                               |
|   12 |  P  | Java types replaced with CW type system                    |
|   16 |  S  | extend-type special form instead of extend-protocol        |
|   51 |  P  | Object fallback delegates to __zig-reduce                  |
|   80 |  P  | Object fallback delegates to CW builtin reduce-kv          |
|   88 |  R  | :extend-via-metadata not supported (Datafiable)            |
|   98 |  R  | :extend-via-metadata not supported (Navigable)             |
|  104 |  S  | Redefine core/reduce dispatch through CollReduce           |

### zip.clj (4)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   78 |  P  | (new Exception) -> (ex-info) for zip exceptions            |
|  187 |  P  | (new Exception) -> (ex-info) for zip exceptions            |
|  198 |  P  | (new Exception) -> (ex-info) for zip exceptions            |
|  270 |  P  | (new Exception) -> (ex-info) for zip exceptions            |

### spec/gen/alpha.clj (4)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    9 |  P  | Lightweight generator (no test.check dependency)           |
|   18 |  S  | Must use clojure.core/array-map (ns excludes hash-map)     |
|  158 |  S  | Avoid syntax-quote in delay macro (CW expansion issues)    |
|  297 |  S  | Must use clojure.core/hash-map for large map literal       |

### stacktrace.clj (2)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   11 |  P  | No cause chains (ex-cause always returns nil)              |
|   20 |  P  | Stack element is [ns/fn file line] vector                  |

## Category Legend

| Cat | Meaning                    | Count | Action                           |
|:---:|----------------------------|------:|----------------------------------|
|  P  | Permanent (Java->Zig)      |    48 | Keep as-is                       |
|  S  | Syntax/bootstrap model     |    12 | Keep as-is                       |
|  R  | Reducible (future feature) |    27 | Resolve when feature implemented |
