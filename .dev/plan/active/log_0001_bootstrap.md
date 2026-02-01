# log_0001_bootstrap

## Task 1.1: Define Value tagged union — DONE

Created src/common/value.zig with Value tagged union. Variants:
nil, boolean, integer, float, char, string, symbol, keyword.
Collections deferred to Task 1.4.

Helper types: Symbol (ns + name), Keyword (ns + name).
Helper methods: isNil(), isTruthy() (Clojure semantics: nil and false are falsy).

11 tests covering creation of all variants, namespaced symbols/keywords,
and truthiness semantics. All passing via TDD (Red -> Green -> Refactor).
