---
name: next
description: >
  Execute exactly one task from the roadmap, then stop and report.
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

## 1. Orient

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
  2. Read Beta reference code as needed
  3. Write task file in `.dev/plan/active/` with detailed `## Plan` + empty `## Log`
  4. Do NOT commit yet — plan goes into the single task commit

## 3. Execute

### For Code Tasks

1. **TDD cycle**: Red -> Green -> Refactor (per CLAUDE.md)
2. **Run tests**: `zig build test`
3. Append progress to task file `## Log`
4. Do NOT commit intermediate steps

### For Planning Tasks

1. Read references, analyze, produce required document
2. Write output to specified path
3. Append progress to task file `## Log`

## 4. Complete

1. Move task file from `active/` to `archive/`
2. Update `roadmap.md` Archive column
3. Advance `memo.md`: update Current task, Task file, Last completed.
   Update Technical Notes with context useful for the next task.
4. **Single git commit** covering plan + implementation + status update

## 5. Report & Stop

After the task is done, report:

- **Task completed**: [task description]
- **Files changed**: [list of modified/created files]
- **Test results**: [pass/fail counts]
- **Next task**: [next pending task from the roadmap]
- **Blockers**: [if any]

Then **stop** — do not proceed to the next task.

## 6. User Instructions

$ARGUMENTS
