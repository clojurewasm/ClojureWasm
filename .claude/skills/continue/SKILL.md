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
- `.dev/plan/memo.md` — current task + task file path + technical notes

## 2. Prepare

- **Task file exists** in `.dev/plan/active/`: read it, resume from `## Log`
- **Task file MISSING** (Task file field is empty):
  1. Read `.dev/plan/roadmap.md` for context + Notes
  2. If the task touches a new subsystem (eval, IO, regex, GC, etc.),
     check `.dev/future.md` for relevant SS section constraints
  3. Read Beta reference code as needed
  4. Write task file in `.dev/plan/active/` with detailed `## Plan` + empty `## Log`
  5. Do NOT commit yet — plan goes into the single task commit

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
3. Advance `memo.md`: update Current task, Task file, Last completed.
   Update Technical Notes with context useful for the next task (root cause, key files, findings).

### 4a.5. Commit Gate Checklist

**MANDATORY** — run the Commit Gate Checklist defined in `CLAUDE.md` §Session Workflow.
(decisions.md D## entry, checklist.md F## updates, vars.yaml, memo.md)

### 4b. Pre-Commit Verification

If `src/common/bytecode/compiler.zig` was modified during this task,
run `/compiler-check` to verify stack_depth, scope, and dual-backend compliance.

### 4c. Git commit (gate)

4. `git add` all changed files (plan + implementation + status)
5. `git commit` — **single commit covering everything for this task**
6. Verify commit succeeded before proceeding

> Do NOT start the next task until the commit is done.
> If design decisions were made, verify they are recorded in `.dev/notes/decisions.md`.

## 5. Phase Completion

When all tasks in a phase are done:

1. Check if the **next phase already exists** in `roadmap.md`
   - **Yes**: Update `memo.md` to point to the first task of the next phase, continue
   - **No**: Plan the next phase (see below)

### Planning a new phase

1. Read `roadmap.md` (completed phases, future considerations)
2. Read `.dev/future.md` — scan SS sections relevant to the new phase:
   - Architecture (SS8), Beta lessons (SS9), compatibility (SS10)
   - Security (SS14) for eval/IO/load tasks, GC/optimization (SS5) for perf tasks
   - Extract any design constraints or requirements into task Notes
3. Read `checklist.md` (bugs, deferred items — prioritize these)
4. Evaluate: **bugs > blockers > deferred items > feature expansion**
5. Create a new phase section in `roadmap.md` with numbered task table
6. Update `memo.md`:
   - Current task → first task of new phase
   - Task file → "(none — create on start)"
   - Technical Notes → context for the first task
   - Clear completed-phase notes
7. Commit: `git commit -m "Add Phase X.Y to roadmap"`
8. Then start the first task normally

## 6. User Instructions

$ARGUMENTS
