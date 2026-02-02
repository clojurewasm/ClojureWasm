# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.6 — Metadata + regex test suite
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.5 completed — regex support

T11.5 added:

1. **Regex engine**: Ported from Beta. `src/common/regex/regex.zig` (parser)
   and `src/common/regex/matcher.zig` (backtracking matcher). Full Java regex
   compatible syntax: character classes, quantifiers, groups, backreferences,
   lookahead, inline flags.
2. **Pattern Value variant**: `regex: *Pattern` in Value union. Compiled
   at analysis time from `#"..."` regex literals. `formatPrStr` shows `#"pattern"`.
3. **Builtins**: `re-pattern`, `re-find`, `re-matches`, `re-seq` — all return
   strings for no-group matches, vectors for group matches.
4. **Analyzer**: `Form.regex` now compiles to Pattern at analysis time (was string).

### Builtin Count

120 builtins registered (was 116, +4: re-pattern, re-find, re-matches, re-seq)
231/702 vars implemented (was 227, +4)
