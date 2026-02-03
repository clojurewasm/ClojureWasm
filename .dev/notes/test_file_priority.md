# Clojure JVM Test File Priority

Prioritized list of remaining test files from `test/clojure/test_clojure/` for porting.
Generated: 2026-02-03 (T14.12)

## Summary

- Total files: 68
- Already ported: 7 (for, control, logic, predicates, atoms, sequences, data_structures)
- Remaining: 61 files

## Priority Categories

### High Priority (Low Java dependency, high value)

Files with minimal Java interop that test core Clojure functionality.
Port these first for maximum test coverage.

| File                | Tests For                  | Java Dep | Notes                                 |
| ------------------- | -------------------------- | -------- | ------------------------------------- |
| macros.clj          | ->, ->>, threading         | None     | Pure Clojure macros                   |
| special.clj         | let, letfn, quote, var, fn | Low      | Special forms, destructuring          |
| multimethods.clj    | defmulti, defmethod        | Low      | Already implemented in ClojureWasm    |
| keywords.clj        | keyword ops, find-keyword  | Low      | Basic keyword tests                   |
| other_functions.clj | identity, fnil, constantly | Low      | Utility functions                     |
| metadata.clj        | meta, with-meta            | Low      | Already implemented in ClojureWasm    |
| clojure_walk.clj    | walk, postwalk, prewalk    | None     | Already implemented in ClojureWasm    |
| clojure_set.clj     | union, intersection, diff  | Low      | Set operations (need clojure.set ns)  |
| string.clj          | clojure.string tests       | Low      | Already implemented in ClojureWasm    |
| vars.clj            | def, defn, binding         | Low      | Var operations                        |
| pprint.clj          | pretty print               | Low      | Not implemented yet, but pure Clojure |
| printer.clj         | print-length, print-level  | Low      | Print control                         |

### Medium Priority (Moderate Java dependency)

Files with some Java but extractable pure Clojure tests.

| File            | Tests For                 | Java Dep | Notes                              |
| --------------- | ------------------------- | -------- | ---------------------------------- |
| def.clj         | defn error messages       | Medium   | Uses ExceptionInfo                 |
| fn.clj          | fn error checking         | Medium   | Uses ExceptionInfo                 |
| ns_libs.clj     | require, use, ns ops      | Medium   | Namespace operations               |
| delays.clj      | delay, force              | Medium   | Uses CyclicBarrier, Thread         |
| evaluation.clj  | eval basics               | Medium   | Uses Compiler class                |
| numbers.clj     | arithmetic, numeric types | Medium   | Uses BigDecimal, Ratio             |
| edn.clj         | edn reader                | Medium   | Generative tests                   |
| test.clj        | clojure.test framework    | Medium   | Test framework tests               |
| transducers.clj | transducers               | Medium   | Needs transient support            |
| volatiles.clj   | volatile!, vswap!         | Low      | Already implemented in ClojureWasm |
| math.clj        | Math functions            | Medium   | Uses Double/compare                |
| errors.clj      | ArityException, errors    | Medium   | Error handling tests               |
| repl.clj        | doc, source, dir          | Medium   | REPL functions                     |

### Low Priority (High Java dependency)

Files heavily dependent on Java interop. Skip or extract minimal tests.

| File              | Tests For                | Java Dep | Notes                     |
| ----------------- | ------------------------ | -------- | ------------------------- |
| agents.clj        | agent, send, send-off    | High     | Requires Java threading   |
| refs.clj          | ref, dosync, STM         | High     | Requires Java STM         |
| parallel.clj      | pmap, pcalls, future     | High     | Requires Java threading   |
| genclass.clj      | gen-class                | High     | JVM-specific              |
| java_interop.clj  | Java interop             | High     | Entirely JVM-specific     |
| compilation.clj   | compile, Compiler        | High     | JVM-specific              |
| protocols.clj     | defprotocol, extend      | High     | Uses Java interfaces      |
| reflect.clj       | reflection               | High     | JVM-specific              |
| serialization.clj | ObjectOutputStream       | High     | JVM-specific              |
| server.clj        | socket REPL              | High     | JVM-specific              |
| streams.clj       | Java streams             | High     | JVM-specific              |
| reducers.clj      | fork/join reducers       | High     | Requires Java ForkJoin    |
| transients.clj    | transient, persistent!   | Medium   | Not implemented yet       |
| try_catch.clj     | exceptions               | High     | Java exception types      |
| annotations.clj   | Java annotations         | High     | JVM-specific              |
| api.clj           | IFn, generative          | High     | Uses clojure.lang classes |
| array_symbols.clj | Array symbols            | High     | JVM-specific              |
| clearing.clj      | Local clearing           | High     | JVM-specific              |
| data.clj          | diff                     | Medium   | Uses HashSet              |
| method_thunks.clj | Method references        | High     | JVM-specific              |
| param_tags.clj    | Parameter tags           | High     | JVM-specific              |
| parse.clj         | parse-long, parse-double | Medium   | Numeric parsing           |
| rt.clj            | RT internals             | High     | JVM-specific              |
| vectors.clj       | vector internals         | Medium   | Uses Java imports         |

### Skip (JVM-specific infrastructure)

| File                        | Reason                   |
| --------------------------- | ------------------------ |
| clojure_xml.clj             | Java XML parser          |
| clojure_zip.clj             | Zipper (not implemented) |
| test_fixtures.clj           | Test infrastructure      |
| run_single_test.clj         | Test runner              |
| ns_libs_load_later.clj      | Test helper              |
| generated\_\*.clj (3 files) | Generated test code      |
| generators.clj              | Generative testing       |
| data_structures_interop.clj | Java interop             |
| main.clj                    | JVM main entry           |

## Recommended Porting Order (Phase 15+)

### Batch 1: Pure Clojure (estimate: 8 files)

1. macros.clj
2. special.clj
3. clojure_walk.clj
4. clojure_set.clj
5. string.clj
6. keywords.clj
7. other_functions.clj
8. metadata.clj

### Batch 2: Core Features (estimate: 6 files)

1. multimethods.clj
2. vars.clj
3. volatiles.clj
4. delays.clj
5. pprint.clj
6. printer.clj

### Batch 3: Advanced (estimate: 4 files)

1. numbers.clj (partial)
2. def.clj (partial)
3. fn.clj (partial)
4. ns_libs.clj (partial)

## Feature Dependencies

Some test files require features not yet implemented:

| File            | Missing Feature                             |
| --------------- | ------------------------------------------- |
| clojure_set.clj | clojure.set namespace (union, intersection) |
| pprint.clj      | clojure.pprint namespace                    |
| transducers.clj | transient/persistent! support               |
| ns_libs.clj     | require/use with :reload                    |

## Notes

- Java-dependent assertions should be commented out with F## reference
- Each ported file should be added to compat_test.yaml
- Focus on behavioral tests, not performance/threading tests
