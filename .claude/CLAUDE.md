# ClojureWasm

Full-scratch Clojure implementation in Zig 0.15.2. "Zig kernel + Clojure world" architecture.
Reference: CW (via add-dir `~/Documents/MyProducts/ClojureWasm`).
Plan: `.dev/references/plan_ja.md`.

## Language Policy

- **All code in English**: identifiers, comments, docstrings, commit messages, markdown

## Architecture

```
Layer 0: src/runtime/    -- Value (NaN boxing), Collections, GC, Env, Dispatch
                            ~160 kernel functions. NO upward imports.
Layer 1: src/eval/       -- Reader, Analyzer, Compiler, VM, TreeWalk, Evaluator
                            imports runtime/ only
Layer 2: src/lang/       -- Primitives (rt/ NS), Interop, Bootstrap, NS Loader
                            imports runtime/ + eval/
Layer 3: src/app/        -- CLI, REPL, nREPL
                            imports anything
         src/main.zig    -- entry point (Layer 3)

modules/                 -- comptime-gated optional modules
                            Each modules/xxx/module.zig exports ModuleDef
                            Registered via runtime/module.zig interface
```

**Key design**: Kernel has ~160 primitives in `rt` namespace.
core.clj references them as `rt/first`, `rt/cons`, etc. (~600 vars in .clj).

Zone details: `.claude/rules/zone_deps.md` (auto-loads on `src/**/*.zig` edits).
Zig pitfalls: `.claude/rules/zig_tips.md` (auto-loads on `src/**/*.zig` edits).

## TDD (t-wada style)

1. **Red**: Write exactly one failing test first
2. **Green**: Write minimum code to pass
3. **Refactor**: Improve code while keeping tests green

- Zig file layout: imports -> pub types/fns -> private helpers -> tests at bottom

## Implementation Quality

- **Root-cause fixes only.** Never patch symptoms.
- **Understand before changing.** Read the full call chain before modifying.
- **Minimal, correct diffs.** Change only what's needed.

## Structural Integrity Rules

1. **No semantic aliasing.** Never register function X under name Y with different semantics.
2. **No evaluator special cases for library features.** Evaluator handles ONLY special forms.
3. **Zone dependency direction is absolute.** Lower layers NEVER import higher layers.
4. **Module isolation.** Core code never imports modules/. Modules register via ModuleDef.

## Critical Rules

- **One task = one commit**. Never batch multiple tasks.
- **Structure changes and logic changes in separate commits.**

## Build & Test

```bash
zig build              # Build (Debug)
zig build test         # Run all tests (no output & status code 0 = success)
zig build test -- "X"  # Specific test only
```

## Notice

**Shell escaping**: For `swap!`, `nil?` etc., write a temp .clj file instead of `-e`.

## Iteration Loop

Every task follows this loop. **Do not skip steps.**

### 1. Orient (every task start)

Read `.dev/memo.md`. Check:
- **Handover notes**: Resolve and delete any remaining items first.
- **Current Task**: If set, continue it. If `(none)`, go to step 1a.

**1a. Pick next task from roadmap**:
- Read `.dev/roadmap.md` **Phase Tracker table only** (top of file).
- Find the first phase with status `IN-PROGRESS` or `PENDING`.
- Search `## Phase N:` to jump to that phase's task list.
- Pick the next unchecked (`[ ]`) task.
- If starting a new phase: update Phase Tracker status to `IN-PROGRESS`.

### 2. Plan

- Write what you will do in memo.md `## Current Task` (1-2 lines).
- Move previous current task to `## Previous Task`.
- If you discover a bug or debt during planning:
  - **Can fix now?** → fix as a separate preceding commit.
  - **Cannot fix now?** → add to `.dev/known_issues.md` with priority (P0-P3).

### 3. Execute (TDD)

- Red → Green → Refactor.
- `bash test/run_all.sh` must pass before committing (falls back to `zig build test` before Phase 2.18).

### 4. Commit

- Mark task done in roadmap.md: `[ ]` → `[x]`.
- Update memo.md: set `## Current Task` to `(none)` or next task.
- Add handover notes only if there is context the next iteration needs.
- If implementing a var → update `.dev/status/vars.yaml` status to `done`.
  - Do not mark it as `done` until it is fully implemented and behaviorally equivalent to upstream.
- If optimization/feature affects performance → `bash bench/bench.sh record` (Phase 8+).
- If a known issue was resolved → **delete it** from known_issues.md.
- If all tasks in a phase are done → update Phase Tracker: `IN-PROGRESS` → `DONE`.
  Also update memo.md `## Current State` with new phase status.
- One task = one commit.

### 4a. Code Reading Doc (Japanese)

After each task commit, generate a Japanese explanation in `private/code_reading/task_XX_YY.md`
(XX = phase, YY = task number, e.g. `task_01_02.md`).

Contents: annotated walkthrough of the code written in the task.
Target audience: the author reviewing later. Include bit layouts, Zig syntax notes,
design rationale, CW diffs, and pointers to future extensions.

**Note**: `private/` is gitignored and NOT tracked. Never use `git add -f` for these files.

### 5. Repeat

Loop back to Orient. Continue until:
- User explicitly requests stop, OR
- Current phase is done AND next phase needs user input.

### Housekeeping

- **memo.md handover notes are ephemeral.** Resolve and delete, don't accumulate.
- **known_issues.md entries should shrink over time.** Fix when opportunity arises.
- **roadmap.md is the source of truth** for task ordering and completion status.

## References

| Topic            | Location                                   | When to read                   |
|------------------|--------------------------------------------|--------------------------------|
| Plan             | `.dev/references/plan_ja.md`               | Architecture, phases, schedule |
| CW reference     | `~/Documents/MyProducts/ClojureWasm/`      | Zig implementation reference   |
| Clojure upstream | `~/Documents/OSS/clojure/src/clj/clojure/` | Read before implementing vars  |
| Zig stdlib       | `/opt/homebrew/Cellar/zig/0.15.2/lib`      | Before writing Zig code        |
