# Project Cleanup Sprint (Pre-Phase 36.8)

Session-spanning tracking document. Read at session start if cleanup incomplete.

## Status

| # | Task                              | Status  | Notes                         |
|---|-----------------------------------|---------|-------------------------------|
| 1 | Benchmark code validity audit     | DONE    | Scripts + CW + multi-lang     |
| 2 | Benchmark execution verification  | DONE    | Fixed hyperfine redirection   |
| 3 | roadmap.md review/fix             | DONE    | 721→159 lines, all phases updated |
| 4 | decisions.md review/prune         | DONE    | 86→25 entries (2126→349 lines) |
| 5 | checklist.md review/prune         | DONE    | Removed F21, F24, F98         |
| 6 | Merge optimization files          | TODO    | catalog + roadmap -> one file |
| 7 | plan/ directory consolidation     | TODO    | Keep: memo, roadmap, archive/ |
| 8 | Top-level directory cleanup       | TODO    | See directory plan below      |
| 10| Path reference integrity check    | TODO    | After all moves, fix refs     |

## Directory Reorganization Plan

### Target top-level structure

```
.claude/           # Claude config (keep)
.clj-kondo/        # Clojure linting (keep)
.dev/              # Development docs + tooling
.github/           # CI (keep)
bench/             # Benchmark suite (keep — high-traffic)
src/               # Source code (keep)
test/              # Tests (keep)
build.zig          # Build file (keep)
build.zig.zon      # Build deps (keep)
flake.lock         # Nix (keep)
flake.nix          # Nix (keep)
.envrc             # direnv (keep)
.gitignore         # (keep)
LICENSE            # (keep)
README.md          # (keep)
```

### Moves/Deletions

| Item          | Action                    | Reason                          |
|---------------|---------------------------|---------------------------------|
| check_size.o  | DELETE                    | Empty build artifact, *.o in gitignore |
| scripts/      | Move to .dev/scripts/     | Tooling, not user-facing        |
| examples/     | Move to .dev/examples/    | Wasm examples, dev reference    |
| docs/         | Move to .dev/docs/        | Internal dev docs, not user docs|
| private/      | KEEP (gitignored)         | User workspace                  |

### bench/ reorganization

| Item              | Action                              |
|-------------------|-------------------------------------|
| bench/history.yaml| Move to .dev/status/history.yaml    |
| bench/simd/       | Keep (benchmark code)               |
| bench/benchmarks/ | Keep                                |
| bench/*.sh        | Keep                                |
| bench/README.md   | Keep                                |

### .dev/ consolidation (notes + plan merge)

Merge `.dev/notes/` and `.dev/plan/` into single `.dev/` flat structure:
- `.dev/memo.md` (was plan/memo.md)
- `.dev/roadmap.md` (was plan/roadmap.md)
- `.dev/optimizations.md` (merged catalog + roadmap)
- `.dev/decisions.md` (was notes/decisions.md)
- `.dev/checklist.md` (stays)
- `.dev/future.md` (stays)
- `.dev/namespace-audit.md` (was notes/)
- `.dev/archive/` (merged plan/archive/ + notes/archive/)
- `.dev/status/` (stays, add history.yaml)
- `.dev/scripts/` (from top-level scripts/)
- `.dev/examples/` (from top-level examples/)
- `.dev/docs/` (from top-level docs/)

### Top-level cleanliness rule (add to CLAUDE.md)

```
## Top-Level Directory Policy
Only these items at repo root: src/, test/, bench/, .dev/, .github/,
build.zig, build.zig.zon, flake.*, .envrc, .gitignore, LICENSE, README.md.
All development docs, scripts, and tooling go under .dev/.
```

## Execution Order

1-2 first (benchmarks — verify before changing anything)
3-5 next (document reviews — content before structure)
6 (merge optimization files)
7-8 (directory moves — structural changes)
10 last (path reference fix — after all moves done)

Each completed task: update this file's Status table, commit.

## Commit Strategy

- One commit per logical unit (may batch 3-5 together as "Document review + prune")
- Directory moves get their own commit (big diff)
- Path fix is the final commit
