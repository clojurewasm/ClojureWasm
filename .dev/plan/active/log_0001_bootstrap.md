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

## Task 1.4: Implement basic collection types (ArrayList-based) — DONE

Created src/common/collections.zig with four persistent collection types:

- PersistentList: `[]const Value` slice, count/first/rest methods
- PersistentVector: `[]const Value` slice, count/nth methods
- PersistentArrayMap: flat `[k1,v1,k2,v2,...]` entries, count/get (linear scan)
- PersistentHashSet: `[]const Value` slice, count/contains (linear scan)

All types include optional `meta: ?*const Value` for future metadata support.

Added collection variants to Value tagged union (as `*const PersistentXxx` pointers).
Extended Value.format for Clojure print semantics: (), [], {k v, ...}, #{}.
Extended Value.eql with:
- Sequential equality: (= '(1 2) [1 2]) => true (Clojure spec)
- Map equality: bidirectional key-value comparison
- Set equality: mutual containment check (order-independent)

Helper functions: isSequential(), sequentialItems() for list/vector abstraction.

10 new collection tests in collections.zig, 13 new tests in value.zig.
Total: ~54 tests. All passing via TDD.

## Task 1.5: Create Tokenizer — DONE

Created src/common/reader/tokenizer.zig (766 lines). Stateful iterator
converting Clojure source text into a token stream.

TokenKind enum (u8) with 28 variants:
- Delimiters: lparen, rparen, lbracket, rbracket, lbrace, rbrace
- Literals: nil, true_lit, false_lit, integer, float, ratio, string, character, keyword, symbol
- Macro chars: quote, deref, meta, syntax_quote, unquote, unquote_splicing
- Dispatch: discard, var_quote, fn_lit, set_lit, regex, symbolic, reader_cond, reader_cond_splicing, ns_map, tag
- Special: eof, invalid

Token struct: kind + start/len (source offset) + line/column for error reporting.

Key design decisions:
- Comma treated as whitespace (Clojure convention)
- # valid inside symbols (gensym: foo#) but dispatches at token start
- Escape processing deferred to Reader stage
- Number support: hex (0x), radix (NNr), ratio (N/N), float, exponent, BigN/BigM suffix
- Shebang (#!) and semicolon comments skipped
- readSymbol checks for nil/true/false literals

27 tests covering: EOF, whitespace, comments, delimiters, symbols, strings,
keywords, numbers (all variants), characters, macro chars, dispatch macros,
regex, tagged literals, line/column tracking, edge cases. All passing via TDD.
