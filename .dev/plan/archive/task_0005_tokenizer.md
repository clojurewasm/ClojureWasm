# Task 0005: Create Tokenizer

## Context

- Phase: 1b (Reader)
- Depends on: task_0004 (Collections)
- References: Beta src/reader/tokenizer.zig (832L), future.md SS14.3

## Plan

1. Create src/common/reader/tokenizer.zig
2. TokenKind enum with all Clojure token variants
3. Stateful iterator converting source text to token stream
4. Comma as whitespace, # dispatch handling, escape processing deferred to Reader

## Log

### 2026-02-01

- Created src/common/reader/tokenizer.zig (766 lines)
- Stateful iterator converting Clojure source text into token stream
- TokenKind enum (u8) with 28 variants:
  - Delimiters: lparen, rparen, lbracket, rbracket, lbrace, rbrace
  - Literals: nil, true_lit, false_lit, integer, float, ratio, string, character, keyword, symbol
  - Macro chars: quote, deref, meta, syntax_quote, unquote, unquote_splicing
  - Dispatch: discard, var_quote, fn_lit, set_lit, regex, symbolic, reader_cond, reader_cond_splicing, ns_map, tag
  - Special: eof, invalid
- Token struct: kind + start/len (source offset) + line/column for error reporting
- Key design decisions:
  - Comma treated as whitespace (Clojure convention)
  - # valid inside symbols (gensym: foo#) but dispatches at token start
  - Escape processing deferred to Reader stage
  - Number support: hex (0x), radix (NNr), ratio (N/N), float, exponent, BigN/BigM suffix
  - Shebang (#!) and semicolon comments skipped
  - readSymbol checks for nil/true/false literals
- 27 tests. All passing via TDD
- Commit: 61474ba "Implement Tokenizer for Clojure source text (Task 1.5)"

## Status: done
