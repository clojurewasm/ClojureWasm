# T14.7: predicates.clj 等価テスト作成

## Goal

Create equivalent tests for type predicates based on clojure/test_clojure/predicates.clj.

## Background

- Original: clojure/test_clojure/predicates.clj (~194 lines)
- Heavy Java dependencies: byte/short/int/long/bigint/bigdec casts, into-array, Date, UUID, URI
- Test style: sample-data map + type-preds table driven testing

## Plan

1. Create test/upstream/clojure/test_clojure/predicates.clj
2. Port tests using simplified data (no Java types):
   - nil?, true?, false?
   - number?, integer?, float? (simplified)
   - symbol?, keyword?
   - string?
   - list?, vector?, map?, set?
   - coll?, seq?
   - fn?, ifn?

## Exclusions

- byte, short, int, long, bigint, bigdec casts — Java interop
- Ratio `2/3` — not supported
- into-array — Java interop
- lazy-seq — may not work identically
- regex `#""` — not supported
- java.util.Date, UUID, URI — Java classes
- class?, var?, delay? — may differ
- NaN?, infinite? — Java Double specific
- Complex table-driven test (simplify to direct assertions)

## Log

2026-02-03: Created predicates.clj with 20 tests, 143 assertions

- Tests: nil?, true?, false?, number?, integer?, float?, symbol?, keyword?,
  string?, char?, list?, vector?, map?, set?, coll?, seq?, fn?, empty?,
  pos?/neg?/zero?, even?/odd?
- Excluded due to ClojureWasm limitations:
  - Empty list () predicates (list?/coll?/seq? return false) → F33
  - seq returns vector instead of seq → F34
  - sequential? not implemented → F35
  - associative? not implemented → F36
  - ifn? not implemented → F37
  - Java types (byte/short/int/long casts, into-array, Date, bigint, bigdec, Ratio, regex)
- All 20 tests pass on TreeWalk
