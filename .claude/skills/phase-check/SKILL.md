---
name: phase-check
description: >
  Check current development phase progress, pending tasks, and blockers.
  Use when user says "progress", "status", "what's next", "phase check",
  or at the start of a session to orient.
  Do NOT use for running tests only (use zig build test directly).
compatibility: Claude Code only. Requires .dev/plan/ directory structure.
metadata:
  author: clojurewasm
  version: 2.0.0
---

# Phase Check

Check progress of the current development phase.

## Steps

1. Read `.dev/plan/memo.md` — identify current phase, task, and technical context
2. Read `.dev/plan/roadmap.md` — check task completion across phases
3. If task file exists in `.dev/plan/active/`, read its `## Log` for recent progress
4. Run `zig build test` — report pass/fail counts
5. List pending tasks and recommend next action
6. Report blockers if any

## Output Format

Summarize as:

- Current phase: Phase N — [name]
- Tasks: X/Y completed (in current phase)
- Tests: N passed, M failed
- Current task: [task description]
- Task file: [path or "not yet created"]
- Next: [recommended action]
- Blockers: [if any]
