---
name: continue
description: >
  Resume autonomous development loop.
  Use when you want unattended continuous execution.
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Write
  - Edit
---

# Autonomous Development Loop

Execute the **Autonomous Workflow** in `CLAUDE.md`.

Keep executing tasks until:

- User requests stop
- Phase queue empty AND next phase undefined

Do NOT stop between tasks. Do NOT ask for confirmation.
When in doubt, pick the most reasonable option and proceed.

$ARGUMENTS
