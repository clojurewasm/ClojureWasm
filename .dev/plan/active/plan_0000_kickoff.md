# plan_0000_kickoff

## Goal

Bootstrap the ClojureWasm project: read Beta design docs, create implementation
plan, set up toolchain, and scaffold the project structure. After completion,
the project is ready for Phase 1 (Reader + Analyzer) implementation.

## References

- Beta: docs/future.md (production design document, sections 0-19)
- Beta: docs/reference/architecture.md (Beta source structure)
- Beta: docs/agent_guide_en.md (agent development guide)

## Tasks

| # | Task                                                          | Status  | Notes                                     |
|---|---------------------------------------------------------------|---------|-------------------------------------------|
| 1 | Read future.md (SS0-19) and architecture.md from Beta         | done    | Understand full design before planning    |
| 2 | Create plan_0001_bootstrap.md (Phase 1-3 implementation plan) | done    | Based on future.md SS19                   |
| 3 | Create .dev/notes/decisions.md (design decisions)             | pending | NaN boxing timing, GC strategy, etc.      |
| 4 | Set up flake.nix + flake.lock                                 | pending | Pin Zig 0.15.2 + toolchain                |
| 5 | Create build.zig scaffold (zig build / zig build test pass)   | pending | Minimal scaffold, tests pass with 0 tests |
| 6 | Create src/ directory structure per future.md SS17            | pending | api/, common/, native/, wasm_rt/, wasm/   |
| 7 | Create docs/adr/0001-nan-boxing.md scaffold                   | pending | ADR template with initial context         |
| 8 | Update settings.json with PostToolUse hook                    | pending | zig build test on Edit/Write              |
| 9 | Update memo.md to point to plan_0001 / Phase 1                | pending | Final kickoff task                        |

## Design Notes

- Tasks 1-3 are planning tasks (documents only, no code)
- Tasks 4-7 are scaffolding tasks (minimal code, project structure)
- Task 8 enables TDD workflow automation
- Task 9 transitions to Phase 1
