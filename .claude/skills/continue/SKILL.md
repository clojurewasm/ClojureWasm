---
name: continue
description: >
  Resume autonomous development. Reads memo.md, finds the next pending task
  in the active plan, and executes tasks in a loop until all are done.
  Use when user says "continue", "keep going", "next tasks", or wants
  unattended autonomous execution.
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# Session Continue (Autonomous Loop)

**When this skill is invoked, keep progressing automatically.**

## 1. Situation Check (every iteration)

```bash
git log --oneline -3
git status --short
```

Read with Read tool:
- `CLAUDE.md` — project instructions, coding conventions
- `.dev/plan/memo.md` — current position, active plan file reference

As needed:
- Active plan file in `.dev/plan/active/` — task details
- Active log file in `.dev/plan/active/` — recent progress

## 2. Task Selection

From the active plan file (referenced in memo.md), find the **first pending task** and begin.

## 3. Iteration Execution

### Development Workflow

1. **TDD cycle**: Red -> Green -> Refactor (per CLAUDE.md)
2. **Run tests**: `zig build test` (when build.zig exists)
3. **Update plan**: mark task as "done" in the active plan file
4. **Update log**: append completion note to the active log file
5. **Update memo.md**: advance "Next task" pointer
6. **Git commit** at meaningful boundaries

### Planning Tasks (no code)

Some tasks produce documents rather than code:
1. Read references, analyze, and produce the required document
2. Write output to the specified path
3. Mark task as "done" in plan, update memo.md
4. Git commit

### Conditional Steps

- **build.zig does not exist yet**: skip `zig build test`
- **Performance tasks**: run benchmarks and record results

### Continuation

- After completing a task, proceed to the next pending task in the plan
- If design decisions are needed, record in `.dev/notes/` and pick the most reasonable option
- Build/test failures: investigate and fix before proceeding
- **IMPORTANT**: do not stop — keep going to the next task

## 4. Phase Completion

When all tasks in the active plan are done:
1. Move plan + log from `.dev/plan/active/` to `.dev/plan/archive/`
2. Add entry to "Completed Phases" table in memo.md
3. Create next phase plan + log in `.dev/plan/active/`
4. Update memo.md to point to the new plan
5. Continue with the first task of the new phase

## 5. User Instructions

$ARGUMENTS
