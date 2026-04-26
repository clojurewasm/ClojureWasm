# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- **Zig 0.16.0 migration COMPLETE** (D111, branch `develop/zig-016-migration`)
- Wasm engine: zwasm v1.11.0 (first 0.16-compatible tag)
- All test suites green: 1324/1324 unit, 83/83 cljw test, 6/6 wasm e2e, deps.edn e2e
- Binary: 4.12MB. Startup: 4.1ms. RSS: 8.2MB (post-migration ReleaseSafe, macOS aarch64)
- Zone violations: 0 (zero — fully clean architecture)
- Coverage: 1,130/1,243 vars done (90.9%), 113 skip, 0 TODO, 27 stubs
- 68 upstream test files

Temporarily stubbed during the migration (each prints a runtime error and
is tracked as a Phase 7 follow-up F## in `.dev/checklist.md`):
- HTTP server (F140), HTTP client (F141)
- nREPL server (F142)
- Raw-mode line editor (F143; runRepl falls through to runReplSimple)
- `cljw build` self-bundling (F144)

## Strategic Direction

**Pure Zig Clojure runtime** (D108). NOT a JVM reimplementation, NOT self-hosting.
CW is a complete, optimized Zig implementation with behavioral Clojure compatibility.

**4-zone layered architecture** (D109). Enforced by commit gate.
- Layer 0: `runtime/` — foundational types (no upward imports)
- Layer 1: `engine/` — processing pipeline (imports runtime/ only)
- Layer 2: `lang/` — Clojure builtins/interop (imports runtime/ + engine/)
- Layer 3: `app/` — CLI/REPL/Wasm (imports anything)

## Current Task

v0.5.0 release prep — Zig 0.16.0 migration is in CHANGELOG `Unreleased`,
docs audited. Ready to tag once `develop/zig-016-migration` lands on main.

## Previous Task

Zig 0.15.2 → 0.16.0 migration (D111). 18 commits on
`develop/zig-016-migration` from `f752739` (Phase -1 audit) through
`aa9dbca` (toolchain flip + Phase 7 follow-ups).

## Task Queue

- Restore stubbed features: F140-F144 (HTTP server/client, nREPL,
  line editor, `cljw build`)
- F145: OrbStack Ubuntu re-validation under 0.16
- F146: strip libc back out

## Known Issues

Full list: `.dev/known-issues.md` (P0-P3).

P0: All RESOLVED.
P1: All RESOLVED.
P2: spec (I-022) → deferred.
P3: UPSTREAM-DIFF markers (I-030), stub vars (I-031), stub namespaces (I-032).

## Notes

- Binary threshold raised to 5.5 MB during the Zig 0.16 migration (gives
  headroom for restoring the four stubbed features and absorbing libc).
- Zone check: `bash scripts/zone_check.sh --gate` (hard block, baseline 0)
- Zone checker now excludes test-only imports (after first `test "..."` in file)
- Phase 98 plan: `.claude/plans/shiny-frolicking-dijkstra.md` (COMPLETE)
- Migration working doc archived: `.dev/archive/zig-016-migration.md`
