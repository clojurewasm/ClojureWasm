# ClojureWasm Development Memo

## Current State

- Phase: 11 (Metadata System + Core Library IV)
- Roadmap: .dev/plan/roadmap.md
- Current task: T11.1b — Reader input validation (depth/size limits)
- Task file: (none)
- Blockers: none

## Technical Notes

Context for the current/next task that a new session needs to know.
Overwrite freely — this is scratchpad, not permanent record.

### T11.1b Background

nREPL server (Phase 7c) is publicly accessible via TCP. Without Reader
input limits, malicious input can cause OOM or stack overflow:

- Deeply nested forms: `(((((((...))))))` — stack overflow in Reader
- Huge string literals: `"<1MB string>"` — memory exhaustion
- Massive collection literals: `[1 2 3 ... 100000]` — allocation pressure

See .dev/future.md SS14.3 for the design:

| Limit                    | Default | Config Flag           |
| ------------------------ | ------- | --------------------- |
| Nesting depth limit      | 1024    | `--max-depth`         |
| String literal size      | 1MB     | `--max-string-size`   |
| Collection literal count | 100,000 | `--max-literal-count` |
| Source file size         | 10MB    | `--max-file-size`     |

Implementation approach: Add depth/size tracking to Reader. Return clear
error messages (not panic) when limits are exceeded.

### T11.2 Additional Requirements

When implementing T11.2 (Var as Value variant), include:

- comptime test verifying no `else => {}` exists in critical Value switch
  statements (SS3: fixup verification institutionalization)
- This prevents silent breakage when new Value variants are added

### Builtin Count

110 builtins registered (was 106, +4: meta, with-meta, alter-meta!, reset-meta!)
216/702 vars implemented (was 211, +5 including vary-meta in core.clj)
