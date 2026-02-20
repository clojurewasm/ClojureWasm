# CLJW / UPSTREAM-DIFF Marker Audit

Last verified: 2026-02-14 (post Phase 70.6)

Total: 120 markers in `src/clj/` (CLJW=83, UPSTREAM-DIFF=37)
Categories: P=90 (permanent), S=17 (syntax/bootstrap), R=13 (reducible)

## UPSTREAM-DIFF Markers (37)

Marks where CW intentionally diverges from upstream Clojure behavior or API shape.

### core.clj (18)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|   45 |  P  | No :inline metadata support (arglists extracted by analyzer)|
|  246 |  P  | No :gen-class (JVM only)                                   |
|  278 |  P  | import registers class short names as symbol vars          |
| 1030 |  P  | Fallback for seq map entries (loop-based reduce-kv)        |
| 1440 |  P  | java.lang classes defined as symbols (JVM auto-imports)    |
| 1617 |  P  | double? equiv to float? (CW uses f64 for all floats)      |
| 1620 |  P  | NaN? pure Clojure (no Double/isNaN)                        |
| 1623 |  P  | infinite? pure Clojure (no Double/isInfinite)              |
| 1626 |  P  | Explicit type check (no ^String type hint)                 |
| 1640 |  R  | nthnext: no IDrop interface, uses loop                     |
| 1647 |  R  | nthrest: no IDrop interface, uses loop                     |
| 1853 |  P  | into uses plain reduce (not coll-reduce protocol)          |
| 1951 |  R  | eduction returns eager sequence (no deftype+IReduceInit)   |
| 1959 |  R  | iteration returns lazy-seq (no reify Seqable+IReduceInit)  |
| 2329 |  P  | class? always returns false (no Java class system)         |
| 2335 |  R  | definline creates fn without :inline metadata              |
| 2477 |  S  | extend-type is special form, not macro                     |
| 2524 |  P  | reduce1->reduce, Java interop->CW equivalents              |

### test.clj (10)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    3 |  R  | Atom-based counters instead of ref-based report-counters   |
|    4 |  P  | do-report does not add file/line info (no StackTraceElement)|
|    5 |  R  | deftest uses register-test atom (not ns metadata)          |
|   18 |  R  | *report-counters* aliases atom-based counters              |
|   21 |  R  | Not a ref, just returns current atom snapshot              |
|   68 |  R  | inc-report-counter uses atoms instead of dosync/commute    |
|  120 |  P  | do-report does not add file/line info (no StackTraceElement)|
|  314 |  P  | thrown-with-msg? uses (str e#) instead of (.getMessage e#) |
|  332 |  P  | try-expr catches Exception instead of Throwable            |
|  461 |  P  | run-test is fn (upstream macro; resolve works at runtime)  |

### spec/alpha.clj (2)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|  140 |  P  | fn-sym always returns nil (no class name decompilation)    |
|  800 |  P  | tagged-ret returns vector instead of MapEntry              |

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
|    5 |  P  | No Java interop (LineNumberReader, Reflector). Has spec.   |

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

## CLJW Markers (83)

Marks CW-specific implementation details, workarounds, and Java->Zig adaptations.

### spec/alpha.clj (28)

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
|  334 |  P  | ^:skip-wiki removed (def no name metadata to var)          |
|  353 |  P  | (ns-name *ns*) instead of (.name *ns*)                     |
|  405 |  P  | ex-info instead of IllegalArgumentException                |
|  448 |  P  | ex-info instead of UnsupportedOperationException           |
|  485 |  P  | random-uuid instead of java.util.UUID/randomUUID           |
|  798 |  P  | tagged-ret uses vector (no MapEntry constructor)           |
|  826 |  P  | random-uuid instead of UUID/randomUUID                     |
| 1102 |  P  | random-uuid instead of UUID/randomUUID                     |
| 1312 |  P  | Long/MAX_VALUE instead of Integer/MAX_VALUE                |
| 1486 |  P  | Long/MAX_VALUE instead of Integer/MAX_VALUE                |
| 1590 |  P  | fspec: conform only checks ifn? (no gen-based testing)     |
| 1631 |  P  | multi-spec-impl adapted for CW defmulti                    |
| 1638 |  P  | Access multimethod internals via CW's defmulti             |
| 1682 |  P  | *compile-asserts* always true (no system properties)       |
| 1685 |  P  | Runtime assert check flag via atom (no RT.checkSpecAsserts)|
| 1734 |  P  | double-in uses CW's double? and math predicates            |
| 1746 |  P  | inst-in stub (no java.util.Date)                           |
| 1750 |  P  | inst types not available                                   |
| 1757 |  P  | inst types not available                                   |

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
|  229 |  P  | Uses defrecord instead of deftype (design decision)        |
|  230 |  P  | Counted/Seqable replaced with protocol implementations     |
|  234 |  P  | Extend Cat with CollReduce/CollFold via extend-type        |
|  260 |  P  | Vector instead of ArrayList                                |
|  274 |  P  | conj instead of .add on ArrayList                          |
|  312 |  S  | Vector fold uses foldvec for divide-and-conquer            |

### core.clj (14)

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
| 2494 |  P  | inst reader returns string (no Date type)                  |
| 2495 |  P  | uuid reader returns string (no UUID type)                  |

### repl.clj (9)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    4 |  S  | Extracted from core.clj (Phase 33.2, D82)                  |
|   95 |  S  | Always emit runtime code (macro_eval_env may lag)          |
|  128 |  P  | (= :regex (type x)) instead of instance? Pattern           |
|  144 |  S  | vec around vals for sort-by compatibility                  |
|  161 |  P  | source-fn reads from filesystem (no classloader)           |
|  201 |  P  | demunge is identity (no JVM name munging)                  |
|  209 |  P  | Simplified root-cause (walks ex-cause chain)               |
|  219 |  P  | Throwable->map trace format (no StackTraceElement)         |
|  228 |  P  | pst uses Zig error stack (no Throwable)                    |

### protocols.clj (8)

| Line | Cat | Description                                                |
|-----:|:---:|------------------------------------------------------------|
|    9 |  S  | ns form handled by bootstrap                               |
|   12 |  P  | Adapted from upstream (Java types replaced)                |
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
|  P  | Permanent (Java->Zig)      |    90 | Keep as-is                       |
|  S  | Syntax/bootstrap model     |    17 | Keep as-is                       |
|  R  | Reducible (future feature) |    13 | Resolve when feature implemented |

## Phase 70.6 Changes

Resolved in 70.6.3: 8 S markers in spec/alpha.clj (syntax-quote :exclude fix).
Resolved in 70.6.4: test.clj report is now defmulti (was R: "dynamic fn").
Resolved in 70.6.5: test.clj is now uses assert-expr (was R: "thrown? standalone").
Added in 70.6.5: test.clj L314 (str vs getMessage), L332 (Exception vs Throwable).
Reclassified in 70.6.6: core.clj L1030, L1853 (R->P), reducers.clj L229-234 (R->P).

## Remaining R Markers (13)

| File | Line | Description                            | Depends on           |
|------|-----:|----------------------------------------|----------------------|
| core | 1640 | nthnext no IDrop                       | IDrop interface      |
| core | 1647 | nthrest no IDrop                       | IDrop interface      |
| core | 1945 | sequence eager (no TransformerIterator)| TransformerIterator  |
| core | 1951 | eduction eager (no IReduceInit deftype)| deftype + IReduceInit|
| core | 1959 | iteration lazy (no reify IReduceInit)  | reify + IReduceInit  |
| core | 2335 | definline no :inline metadata          | compiler :inline     |
| test |    3 | atom counters (no refs/STM)            | STM (ref/dosync)     |
| test |    5 | deftest atom registry                  | STM (ref/dosync)     |
| test |   18 | *report-counters* atom alias           | STM (ref/dosync)     |
| test |   21 | atom snapshot (not ref)                | STM (ref/dosync)     |
| test |   68 | atoms instead of dosync/commute        | STM (ref/dosync)     |
| prot |   88 | :extend-via-metadata Datafiable        | Protocol metadata ext|
| prot |   98 | :extend-via-metadata Navigable         | Protocol metadata ext|
