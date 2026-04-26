# Session handover

> Read at session start. Update at session end. Short, mutable, current-state
> only. Long-lived items go in `known_issues.md`. Authoritative project plan
> is `ROADMAP.md`.

## Current state

- **Phase**: pre-Phase-1. Bootstrap and audit-pass complete.
- **Branch**: `cw-from-scratch` (long-lived, branched from v0.5.0).
- **Last commit**: `116b874 chore: bootstrap project — build, docs, license, learning-doc gate` (plus the audit-pass commit that introduced this file).
- **Build**: `zig build` / `zig build test` / `zig build run` all green; `cljw` artifact prints `ClojureWasm`.

## Current task

(none — waiting for Phase 1 kickoff)

## Next up

ROADMAP §9, Phase 1: Value + Reader + Error + Arena GC.

Concrete first task (`1.1` per the future per-Phase task list, to be
written when Phase 1 starts):

- Decide whether to maintain a per-Phase task list in this file or split
  it into `.dev/phases/PHASE-NN.md`. (Old FromScratch used a long
  `.dev/roadmap.md`; current approach is to extend ROADMAP §9 inline.)

## Open design questions for Phase 1 entry

- Heap type slot allocation final form (32-slot grid in ROADMAP §4.2 needs
  review against any new Group D additions for `class` Value).
- Reader Phase-1 scope: confirm syntax-quote / unquote stay deferred to
  Phase 3 per old FromScratch precedent.
- Whether to write a draft ADR for "Reader 3-file split" before starting
  Phase 1, or to write it after the implementation fits.

## Recent decisions / context not yet on disk

(none)
