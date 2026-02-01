---
name: next
description: >
  Execute exactly one task from the active plan, then stop and report.
  Use when user says "next", "one task", "do the next task", or wants
  controlled single-step execution with a completion report.
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# Execute Next Task (Single Step)

**Execute exactly one task, then report and stop.**

## 1. Situation Check

```bash
git log --oneline -3
git status --short
```

Read with Read tool:
- `CLAUDE.md` — project instructions
- `.dev/plan/memo.md` — current position, active plan file reference
- Active plan file in `.dev/plan/active/` — task details

## 2. Task Selection

From the active plan file, find the **first pending task**.

## 3. Execute One Task

### For Code Tasks
1. **TDD cycle**: Red -> Green -> Refactor (per CLAUDE.md)
2. **Run tests**: `zig build test` (when build.zig exists)
3. Mark task as "done" in the active plan file
4. Append completion note to the active log file
5. Update "Next task" in memo.md
6. Git commit

### For Planning Tasks
1. Read references, analyze, produce required document
2. Write output to specified path
3. Mark task as "done", update memo.md
4. Git commit

### Conditional Steps
- **build.zig does not exist yet**: skip `zig build test`

## 4. Completion Report

After the task is done, report:

- **Task completed**: [task description]
- **Files changed**: [list of modified/created files]
- **Test results**: [pass/fail counts, or "build.zig not yet created"]
- **Next task**: [next pending task from the plan]
- **Blockers**: [if any]

Then **stop** — do not proceed to the next task.

## 5. User Instructions

$ARGUMENTS
