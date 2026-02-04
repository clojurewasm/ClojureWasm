# ClojureWasm Development Memo

Session handover document. Read at session start.

## Current State

- Phase: 18.7 (Core Coverage Sprint II)
- Next task: T18.7.3
- Coverage: 405/712 clojure.core vars done
- Blockers: none

## Task Queue

| Task    | Description        | Notes                           |
| ------- | ------------------ | ------------------------------- |
| T18.7.3 | Hierarchy basics   | parents, descendants, ancestors |
| T18.7.4 | Coverage expansion | Tests for T18.7.1-3 features    |

## Current Task

Write task design here at iteration start.
On next task, move this content to Previous Task below.

## Previous Task

(empty)

## Handover Notes

Notes that persist across sessions.

- Phase 18.7 goal: sprint toward 400+ done vars
- make-hierarchy already defined in core.clj (T18.7.1)
- After current phase: plan Upstream Alignment (Phase 18.5) or new sprint
- Hierarchy approach: global hierarchy map in Zig, derive/underive modify,
  parents/ancestors/descendants query
