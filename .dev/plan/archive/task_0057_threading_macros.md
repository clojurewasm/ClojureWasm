# T7.3: Missing Core Macros — Threading Variants + Utility

## Goal

Add missing threading macros and utility macros to core.clj:

- doto, as->, cond->, cond->>, some->, some->>
- condp, case (if straightforward)

All pure Clojure macros, no Zig changes needed.

## Plan

1. Implement doto (thread first arg, return original)
2. Implement as-> (named threading)
3. Implement cond-> / cond->> (conditional threading)
4. Implement some-> / some->> (nil-safe threading)
5. Add tests for each

## Log

- Starting T7.3
- Added doto, as->, some->, some->>, cond->, cond->> to core.clj
- Key insight: auto-gensym (foo#) scoped per syntax-quote, so macros using
  map+fn with inner syntax-quotes need manual form construction (cons/list)
  instead of nested syntax-quote with gensym references
- Used fixed symbols (**doto_val**, **some_val**, **cond_val**) as workaround
- All 660 tests pass; 146 vars (was 140)
- DONE
