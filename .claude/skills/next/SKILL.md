---
name: next
description: >
  Execute exactly one task, then stop and report.
  Use when you want controlled single-step execution.
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

Execute the **Autonomous Workflow** in `CLAUDE.md` with one modification:

**Stop after completing ONE task** (do not loop).

After task completion, report:

- Task completed: [description]
- Files changed: [list]
- Test results: [pass/fail]
- Next task: [from memo.md]

$ARGUMENTS
