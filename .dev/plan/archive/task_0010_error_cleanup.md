# Task 0010: Error System Cleanup — Unified Error + Python-Style Kind

## Goal

Remove ReadError/AnalysisError subsets and compress Kind enum (18->12) using
Python-style categories. Helpers (makeError, analysisError) are kept but simplified.

## References

- D3b in .dev/notes/decisions.md
- Python exception hierarchy (SyntaxError, ValueError, TypeError, etc.)

## Plan

1. Rewrite error.zig: Kind 18->12, Error 14->12, remove subsets/phase helpers
2. Update reader.zig: ReadError->Error, simplify makeError, update Kind values
3. Update analyzer.zig: AnalyzeError->Error, simplify analysisError, update Kind values
4. Run tests, grep for stale references
5. Update docs (decisions.md, roadmap.md, memo.md)

## Kind Mapping

| Old (18)            | New (12)         |
| ------------------- | ---------------- |
| unexpected_eof      | syntax_error     |
| invalid_token       | syntax_error     |
| unmatched_delimiter | syntax_error     |
| invalid_number      | number_error     |
| invalid_character   | string_error     |
| invalid_string      | string_error     |
| invalid_regex       | string_error     |
| invalid_keyword     | name_error       |
| undefined_symbol    | name_error       |
| invalid_arity       | arity_error      |
| invalid_binding     | value_error      |
| duplicate_key       | value_error      |
| division_by_zero    | arithmetic_error |
| index_out_of_bounds | index_error      |
| type_error          | type_error       |
| (new)               | io_error         |
| internal_error      | internal_error   |
| out_of_memory       | out_of_memory    |

## Log

- Started: error system cleanup task
- Rewrote error.zig: Kind 18->12, Error 14->12, removed subsets + phase helpers, added setErrorFmt
- Updated reader.zig: ReadError=err.Error, simplified makeError, updated all Kind values + tests
- Updated analyzer.zig: AnalyzeError=err.Error, simplified analysisError, updated all Kind values + tests
- All tests pass, grep confirms zero stale references
- Updated decisions.md, roadmap.md, memo.md
