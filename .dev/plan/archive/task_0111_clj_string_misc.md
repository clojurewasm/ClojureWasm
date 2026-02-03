# T13.5: clojure.string — blank?, reverse, trim-newline, triml, trimr

Phase 13b — clojure.string namespace completion

## Goal

Add remaining commonly-used string functions to clj_string.zig.

## Result

- 5 functions added: blank?, reverse, trim-newline, triml, trimr
- Builtins table: 9 → 14 entries
- blank? handles nil, empty, and whitespace-only strings
- reverse preserves UTF-8 codepoint boundaries
- trim-newline removes only \r and \n (not all whitespace)

## Log

- TDD: wrote 6 tests (Red), then implemented (Green)
- All unit + SCI tests pass (72/74, 259 assertions)
- E2E verified via TreeWalk
