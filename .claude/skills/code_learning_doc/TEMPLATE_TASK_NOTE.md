<!-- Per-task short note. Lives in private/notes/<phase>-<task>.md (gitignored).
     Five minutes to fill in. English, per CLAUDE.md language policy.
     No em-dashes, no padding. State the fact and stop. -->

---
task: §9.X.Y
commits:
  - <SHA>            # the source commit(s) this note covers
date: YYYY-MM-DD
files:
  - src/<path>.zig
---

## Summary

<one line: what works now that did not before>

## What was non-obvious

1. <finding 1>
2. <finding 2>
3. <finding 3>

## Comparison against the textbooks

- **cw v0** (git tag `v0.5.0`, via `git worktree add ../cw-v0 v0.5.0`):
  <what v0 does, filename + one line>
- **Clojure JVM / Babashka / Zig stdlib**:
  <only when relevant>
- **DIVERGENCE**: <where this project deliberately differs, and why>

## Design decisions

- <decision, and the alternative it beat>

## Worth citing later

- <the thing a future reader would otherwise have to re-derive>
