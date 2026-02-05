# Test Porting Gap Analysis

Created: 2026-02-05

## Overview

Upstream JVM Clojure `test/clojure/test_clojure/` has ~67 `.clj` test files.
Currently 30 files ported, 37 unported. Ported files contain many CLJW-marked
skips/adaptations that may now be resolvable.

Policy: minimize skips — implement in Zig or Clojure where possible, skip only
for physically impossible JVM interop (class hierarchy, threading, reflection).

---

## Part A: Skipped Tests in Already-Ported Files

### A1. Already-Implemented Features Still Skipped (revive immediately)

These features were unimplemented when tests were ported but are now **done**.
Tests can be revived by editing the test files — no new implementation needed.

| File               | Skipped Content                           | Required Feature            | vars.yaml |
|--------------------|-------------------------------------------|-----------------------------|-----------|
| clojure_walk.clj   | sorted-set-by, sorted-map-by removed      | sorted-set-by, sorted-map-by| done      |
| clojure_walk.clj   | walk-mapentry test skipped entirely        | map-entry?                  | done      |
| control.clj        | sorted-map, sorted-set removed from case  | sorted-set, sorted-map      | done      |
| sequences.clj      | sorted-set tests removed (~6 locations)   | sorted-set, sorted-set-by   | done      |
| sequences.clj      | partitionv test marked "JVM interop"      | partitionv                  | done      |
| data_structures.clj| sorted-map/set tests marked "JVM interop" | sorted-set, sorted-map      | done      |
| special.clj        | 3 tests: eval + CompilerException         | eval                        | done      |
| vars.clj           | with-redefs tests marked "JVM interop"    | with-redefs, promise, deliver| done     |

### A2. Small Implementation Needed

| File              | Skipped Content                 | Needed                     | Feasibility   |
|-------------------|---------------------------------|----------------------------|---------------|
| keywords.clj      | test-find-keyword (1 test)     | find-keyword (F80)         | Yes — intern  |
| parse.clj         | test-parse-uuid (1 test)       | parse-uuid function        | Yes — small   |
| for.clj           | Destructuring (1 test)         | {:syms [a b c]} destructure| Yes — analyzer|
| fn.clj            | first-param-as-args (1 test)   | analyzer behavior fix      | Yes — small   |
| printer.clj       | print-meta (1 test)            | string predicate in test   | Yes — trivial |
| printer.clj       | print-symbol-values (1 test)   | ##Inf/##NaN pr-str         | Yes — small   |
| printer.clj       | print-dup-readable (1 test)    | *print-dup* full impl      | Yes — medium  |
| math.clj          | 3 assertions deferred          | float literal precision    | Yes — small   |
| transducers.clj   | test-eduction (2 tests)        | eduction + IReduceInit     | Yes — medium  |
| sequences.clj     | test-iteration (2 tests)       | iteration function         | Yes — medium  |
| other_functions.clj| test-regex-matcher (1 test)   | re-matcher, re-groups      | Yes — medium  |
| multimethods.clj  | with-var-roots (2 tests)       | test helper macro          | Yes — small   |
| metadata.clj      | 3 tests skipped                | eval-in-temp-ns            | Partial       |
| evaluation.clj    | 2 tests skipped                | defstruct, CompilerExc.    | Partial       |

### A3. Numeric Type Gaps (large implementation)

| File           | Skipped Content                | Needed          | Feasibility     |
|----------------|--------------------------------|-----------------|-----------------|
| numbers.clj    | Ratio tests (~8 + assertions)  | Ratio type (F3) | Yes — large     |
| numbers.clj    | BigDecimal tests (~5)          | BigDecimal      | Yes — large     |
| numbers.clj    | BigInteger tests (~3)          | BigInteger      | Yes — large     |
| logic.clj      | type cast assertions removed   | byte/short/etc  | Partial         |
| control.clj    | 2/3, 0M/1M removed            | Ratio+BigDecimal| Yes — large     |
| transducers.clj| 1.0M, 1N removed              | BigDecimal/Int  | Yes — large     |

### A4. Pure JVM Interop (cannot implement)

| File               | Skipped Content                             | Reason                        |
|--------------------|---------------------------------------------|-------------------------------|
| vectors.clj        | vector-of :int/:long (3 tests)              | JVM primitive arrays          |
| vectors.clj        | Spliterator/Stream (4 tests)                | Java Stream API               |
| vectors.clj        | .containsKey/.entryAt (2 tests)             | Java collection interface     |
| data_structures.clj| java.util.HashMap/HashSet assertions        | Java collections              |
| data_structures.clj| into-array assertions                       | Java arrays                   |
| data_structures.clj| defspec generative tests                    | clojure.test.generative       |
| data_structures.clj| IReduce, .iterator (2 tests)                | Java interface methods        |
| delays.clj         | Thread/CyclicBarrier (3 tests)              | Multi-threading               |
| delays.clj         | java.util.function.Supplier (1 test)        | Java functional interface     |
| errors.clj         | demunge, ArityException (4 tests)           | JVM name mangling / fields    |
| errors.clj         | CompilerException (1 test)                  | JVM Compiler class            |
| errors.clj         | Throwable->map chain (2 tests)              | JVM stack trace format        |
| string.clj         | char-sequence-handling (1 test)             | StringBuffer                  |
| printer.clj        | print-ns-maps (1 test)                      | pprint, bean, java.util.Date  |
| transducers.clj    | test.check, TransformerIterator (3 tests)   | External lib / JVM internal   |
| logic.clj          | into-array, java.util.Date assertions       | Java types                    |
| numbers.clj        | Java arrays, Float./Double. (5+ tests)      | Java constructors             |
| special.clj        | .indexOf, should-not-reflect (1 test)       | Java method / reflection      |

---

## Part B: Unported Files

### B1. Portable (can port)

| File              | Lines | Tests | Content                     | Notes                              |
|-------------------|-------|-------|-----------------------------|------------------------------------|
| test.clj          |   129 |    14 | clojure.test framework      | is/are/testing done; report needed |
| test_fixtures.clj |    73 |     5 | use-fixtures, setup/teardown| use-fixtures impl needed           |
| edn.clj           |    38 |   ~1  | EDN read/read-string        | Thin wrapper over existing reader  |
| ns_libs.clj       |   144 |    10 | require, import, ns ops     | ns machinery already works         |
| repl.clj          |    61 |     7 | doc, source, dir, apropos   | doc feasible, source needs file IO |
| data.clj          |    32 |     1 | clojure.data/diff           | Protocol-based, clojure.data=todo  |
| refs.clj          |    22 |   ~1  | ref, dosync, STM            | Single-thread lightweight STM ok   |
| try_catch.clj     |    39 |     2 | try/catch/finally basics    | try/catch implemented; partial JVM |
| rt.clj            |   104 |     4 | Runtime, binding validation | Some tests portable                |
| main.clj          |    78 |     4 | REPL main function          | Partial — some JVM (System/*)      |

### B2. Partially Portable

| File          | Lines | Tests | Portable Subset              | JVM-Only Subset                  |
|---------------|-------|-------|------------------------------|----------------------------------|
| protocols.clj |   721 |    25 | defprotocol, extend, satisfies?| deftype(skip), Java class extend|
| reducers.clj  |    95 |     5 | fold basics                  | Parallel fold (forkjoin)         |
| pprint.clj    |    20 |   ~0  | Basic format                 | pprint ns 0/26 done — large impl|
| api.clj       |    54 |   ~0  | Clojure/read API             | Generative tests                 |

### B3. Difficult (mostly JVM)

| File              | Lines | Tests | Reason                               |
|-------------------|-------|-------|--------------------------------------|
| agents.clj        |   195 |     9 | agent/send/await — threads required  |
| parallel.clj      |    40 |     2 | pmap, future — threads required      |
| serialization.clj |   192 |     8 | Java ObjectOutputStream              |
| clearing.clj      |   110 |     3 | JVM closure clearing optimization    |
| method_thunks.clj |    62 |     4 | Java method signature selection      |

### B4. Cannot Port (fully JVM-specific)

| File                          | Lines | Tests | Reason                        |
|-------------------------------|-------|-------|-------------------------------|
| java_interop.clj              |   891 |    41 | Java interop, . forms         |
| compilation.clj               |   445 |    31 | Compiler API, type hints      |
| genclass.clj                  |   161 |     7 | gen-class/gen-interface       |
| param_tags.clj                |   220 |     8 | Java array type tags          |
| reflect.clj                   |    63 |     5 | Java Reflection API           |
| streams.clj                   |   103 |     5 | Java Stream API               |
| server.clj                    |    47 |     2 | Socket server                 |
| data_structures_interop.clj   |   131 |     0 | Java Iterator API             |
| annotations.clj               |    19 |     0 | Java annotations              |
| array_symbols.clj             |    81 |     2 | Java array type symbols       |
| clojure_xml.clj               |    30 |     1 | Java XML parser               |
| generated_*_adapters*.clj (3) |   714 |     0 | Java FI adapters              |

### B5. Utility / Not Needed

| File                  | Content                      | Verdict                        |
|-----------------------|------------------------------|--------------------------------|
| generators.clj        | test.check generators        | Not needed — no test.check     |
| run_single_test.clj   | Test runner helper           | Not needed — own runner        |
| ns_libs_load_later.clj| Helper for ns_libs.clj      | Needed only with ns_libs.clj   |

---

## Part C: Implementation Feasibility Summary

### Tier 1 — Immediate (test revival only, features already done)

Revive skipped tests in 4+ ported files. ~25 tests recoverable.

- sorted-set / sorted-set-by / sorted-map / sorted-map-by (4 files)
- map-entry? (clojure_walk)
- partitionv (sequences)
- with-redefs / promise / deliver (vars — non-threaded tests only)
- eval (special — non-JVM-exception tests)

### Tier 2 — Small implementation + new file ports

- find-keyword (F80), parse-uuid, {:syms} destructure
- edn.clj port (clojure.edn thin wrapper)
- try_catch.clj port (basic subset)
- ##Inf/##NaN print, *print-dup*, float literal precision
- with-var-roots test helper

### Tier 3 — Medium implementation + new file ports

- eduction + iteration functions
- test.clj + test_fixtures.clj ports (use-fixtures impl)
- ns_libs.clj port
- data.clj port (clojure.data/diff)
- protocols.clj partial port
- re-matcher / re-groups

### Tier 4 — Large implementation (future phases)

- Ratio type (F3) — unlocks ~30 assertions across 4+ files
- clojure.zip full namespace (28 functions, pure Clojure)
- BigDecimal / BigInteger
- pprint (26 functions)
- STM (ref/dosync — single-thread)

### Cannot Implement (JVM-only)

12 files fully impossible + 5 files mostly impossible.
~177 tests total in these files.
