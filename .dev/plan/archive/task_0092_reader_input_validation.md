# T11.1b: Reader Input Validation (Depth/Size Limits)

## Goal

Add input validation limits to the Reader to prevent OOM and stack overflow
from malicious/malformed input via nREPL or file execution.

## Design (from .dev/future.md SS14.3)

| Limit                    | Default | Config Flag           |
| ------------------------ | ------- | --------------------- |
| Nesting depth limit      | 1024    | `--max-depth`         |
| String literal size      | 1MB     | `--max-string-size`   |
| Collection literal count | 100,000 | `--max-literal-count` |
| Source file size         | 10MB    | `--max-file-size`     |

Limit exceeded -> clear error message (not panic).

## Plan

### 1. Add ReaderLimits config struct

Add a `ReaderLimits` struct to reader.zig with configurable defaults:

- `max_depth: u32 = 1024`
- `max_string_size: u32 = 1_048_576` (1MB)
- `max_collection_count: u32 = 100_000`

Source file size check is done at the call site (bootstrap/CLI/nREPL) before
Reader.init, not inside Reader itself.

### 2. Add depth tracking to Reader

- Add `depth: u32 = 0` field to Reader struct
- Add `limits: ReaderLimits` field to Reader struct
- Increment depth at readDelimited entry, decrement on exit
- Also track depth in readWrapped, readMeta, readFnLit, readSyntaxQuote
  (any function that calls readForm recursively)
- Check depth against limits.max_depth, return error if exceeded

### 3. Add string size check

- In readString, after getting token text, check len against limits.max_string_size
- Return clear error message: "String literal exceeds maximum size"

### 4. Add collection element count check

- In readDelimited, check items.len against limits.max_collection_count
- Return error: "Collection literal exceeds maximum element count"

### 5. Add source file size check

- In bootstrap.readForms, check source.len against a max_file_size limit
- In nREPL eval, check input size before passing to reader
- In CLI file read, check file size before reading

### 6. Wire CLI flags

- Add --max-depth, --max-string-size, --max-literal-count, --max-file-size
  to CLI arg parser
- Pass limits through to Reader via bootstrap

### 7. Tests (TDD)

- Depth limit: nested `((((...))))` exceeding 1024 -> error
- String size: oversized string -> error
- Collection count: `[1 2 3 ... 100001]` -> error
- Normal input within limits -> still works
- Custom limits -> respected

## Log

### Red: Tests for depth, string size, collection count limits

- Added Reader.Limits struct + initWithLimits constructor
- Added readOneWithLimits test helper
- 9 tests: depth exceeded/ok, collection count exceeded/ok, string size exceeded/ok,
  default limits, nested vectors/maps, reader macros depth tracking

### Green: Implement limits

- Depth tracking via enterDepth helper in readDelimited, readWrapped, readDiscard, readMeta
- Collection element count check in readDelimited loop
- String literal size check in readString
- File size limit: CLI readFileAlloc now 10MB (was 1MB)
- nREPL: 1MB input size limit before eval

### Refactor: Extract enterDepth helper

- Replaced 4 inline depth check blocks with enterDepth(line, column) + defer self.depth -= 1
- All tests pass, CLI verified
