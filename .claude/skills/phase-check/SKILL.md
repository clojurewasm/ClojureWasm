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
  version: 1.0.0
---

# Phase Check

Check progress of the current development phase.

## Steps

1. Read `.dev/plan/memo.md` — identify current phase and position
2. Read active plan file in `.dev/plan/active/` — check task completion
3. Run `zig build test` — report pass/fail counts (skip if build.zig does not exist)
4. List pending tasks and recommend next action
5. Report blockers if any
6. Show latest entry from the active log file in `.dev/plan/active/`

## Output Format

Summarize as:
- Current phase: Phase N — [name]
- Tasks: X/Y completed
- Tests: N passed, M failed (or "build.zig not yet created")
- Next: [recommended task]
- Blockers: [if any]
