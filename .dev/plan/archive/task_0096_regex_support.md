# T11.5: re-pattern, re-find, re-matches, re-seq

## Overview

Add regex support: compile `#"..."` literals, Value.regex variant, and
Clojure regex builtins (re-pattern, re-find, re-matches, re-seq).

Port Beta's regex engine (regex.zig parser + matcher.zig backtracking matcher)
into the production codebase.

## Plan

### Step 1: Port regex engine from Beta

- Copy `src/regex/regex.zig` (parser) and `src/regex/matcher.zig` (matcher)
  from Beta to `src/common/regex/regex.zig` and `src/common/regex/matcher.zig`
- Adapt imports: Beta uses different module paths
- Update `build.zig` to include new source directory
- Ensure tests pass in isolation

### Step 2: Add regex Value variant

- Add `Pattern` struct to value.zig: `{ source: []const u8, compiled: *const anyopaque }`
- Add `regex: *Pattern` variant to Value tagged union
- Update formatPrStr: `#"pattern"`
- Update eql: compare source strings (like Clojure)
- Update all switch statements (macro.zig, predicates.zig, tree_walk.zig, main.zig, nrepl.zig)

### Step 3: Wire analyzer to compile regex literals

- Change analyzer: `Form.regex` → compile to Pattern, store as `.regex` constant
- This makes `#"\\d+"` produce a compiled Pattern value at analysis time

### Step 4: Add regex builtins (strings.zig or new regex_builtins.zig)

- `re-pattern`: string → Pattern (compile), Pattern → Pattern (identity)
- `re-find`: (pattern, string) → first match result
- `re-matches`: (pattern, string) → full match result
- `re-seq`: (pattern, string) → list of all matches
- Match results: string for no capture groups, vector for groups

### Step 5: Register builtins + update vars.yaml

### Step 6: Integration tests (E2E + compare mode)

## Log

- Ported regex engine from Beta: regex.zig (parser) + matcher.zig (backtracking)
- Added Pattern struct and regex Value variant to value.zig
- Updated all Value switch statements (10+ files)
- Wired analyzer to compile regex literals at analysis time
- Added re-pattern, re-find, re-matches, re-seq builtins
- Registered builtins in registry (116 → 120)
- Added root.zig entries for test coverage
- E2E tests pass on both VM and TreeWalk backends
- Regex literal #"..." compiles and works
- Builtin count: 116 → 120, vars: 227 → 231
