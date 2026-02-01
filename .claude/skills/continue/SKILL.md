---
name: continue
description: >
  Resume autonomous development. Reads memo.md, finds the current task,
  and executes tasks in a loop until all are done or context runs out.
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

## 1. Orient (every iteration)

```bash
git log --oneline -3
git status --short
```

Read with Read tool:

- `CLAUDE.md` — project instructions
- `.dev/plan/memo.md` — current task + task file path

## 2. Prepare

- **Task file exists** in `.dev/plan/active/`: read it, resume from `## Log`
- **Task file MISSING** (Task file field is empty):
  1. Read `.dev/plan/roadmap.md` for context + Notes
  2. Read Beta reference code as needed
  3. Write task file in `.dev/plan/active/` with detailed `## Plan` + empty `## Log`
  4. Do NOT commit yet — plan goes into the single task commit

## 3. Execute

### Development Workflow

1. **TDD cycle**: Red -> Green -> Refactor (per CLAUDE.md)
2. **Run tests**: `zig build test`
3. Append progress to task file `## Log`
4. Do NOT commit intermediate steps

### Planning Tasks (no code)

1. Read references, analyze, produce required document
2. Write output to specified path
3. Append progress to task file `## Log`

### Continuation

- After completing a task, proceed to the next pending task
- If design decisions are needed, record in `.dev/notes/` and pick the most reasonable option
- Build/test failures: investigate and fix before proceeding
- **IMPORTANT**: do not stop — keep going to the next task

## 4. Complete (per task)

**CRITICAL: Always commit before moving to the next task.**

### 4a. Finalize bookkeeping

1. Move task file from `active/` to `archive/`
2. Update `roadmap.md` Archive column
3. Advance `memo.md` to next task (clear Task file path)

### 4b. Git commit (gate)

4. `git add` all changed files (plan + implementation + status)
5. `git commit` — **single commit covering everything for this task**
6. Verify commit succeeded before proceeding

> Do NOT start the next task until the commit is done.
> If design decisions were made, verify they are recorded in `.dev/notes/decisions.md`.

## 5. Phase Completion

When all tasks in a phase are done:

1. Add entry to "Completed Phases" table in `memo.md`
2. Continue with the first task of the next phase

## 6. User Instructions

$ARGUMENTS
