# T13.10: Upstream alignment (UPSTREAM-DIFF cleanup)

Phase 13d — Validation + Upstream Alignment

## Goal

Replace simplified core.clj definitions with upstream-equivalent code.

## Result

- memoize: replaced contains?/get pattern with if-let/find/val (upstream verbatim)
- trampoline: replaced loop/recur with let+recur (upstream style)
- Both UPSTREAM-DIFF notes removed from vars.yaml
- No UPSTREAM-DIFF notes remain

## Log

- find was already implemented as a builtin
- if-let macro was already available
- val builtin was added in T13.6
- Both changes verified via SCI tests: 72/72, 267 assertions
