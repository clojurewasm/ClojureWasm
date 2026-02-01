# log_0001_bootstrap

## Task 1.1: Define Value tagged union — DONE

Created src/common/value.zig with Value tagged union. Variants:
nil, boolean, integer, float, char, string, symbol, keyword.
Collections deferred to Task 1.4.

Helper types: Symbol (ns + name), Keyword (ns + name).
Helper methods: isNil(), isTruthy() (Clojure semantics: nil and false are falsy).

11 tests covering creation of all variants, namespaced symbols/keywords,
and truthiness semantics. All passing via TDD (Red -> Green -> Refactor).

## Task 1.2: Implement Value.format (print representation) — DONE

Added Value.format() using Zig 0.15 `{f}` format spec (1-arg signature).
Clojure pr-str semantics for all current variants:

- nil -> "nil", boolean -> "true"/"false"
- integer -> decimal, float -> decimal with guaranteed decimal point (0.0 not 0)
- char -> special names (\newline, \space, \tab, \return) + UTF-8 for others
- string -> quoted with double quotes
- symbol -> ns/name or name, keyword -> :ns/name or :name

Test helper `expectFormat` for concise format assertions.
9 new format tests (20 total). All passing via TDD.

## Task 1.3: Implement Value.eql (equality) — DONE

Added Value.eql() with Clojure = semantics:

- Same-type structural comparison for all variants
- Cross-type numeric equality: (= 1 1.0) => true via f64 conversion
- Symbol/Keyword: compare both name and ns (namespace)
- String: byte-level comparison via std.mem.eql
- Different types => false (except int/float cross-comparison)

Helper: eqlOptionalStr for ?[]const u8 comparison.
11 new eql tests (31 total). All passing via TDD.
Collection equality deferred to Task 1.4.
