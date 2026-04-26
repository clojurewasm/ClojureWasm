# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.

## Current state

- **Phase**: Phase 1 IN-PROGRESS (1.0 done; 1.1 next).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired commit**: doc commit covering bootstrap / audit /
  simplification / continuity-fixes — see `git log --oneline` for the
  exact head.
- **Build**: `zig build` / `zig build test` / `zig build run` are green
  on the bootstrap (`cljw` prints `ClojureWasm`).

## Unpaired source commits awaiting a doc

(none — last commit is the doc commit)

## Next task

`§9.3 / 1.1` — `src/runtime/value.zig`: NaN-boxed `Value` type, `HeapTag`
(32 slots), `HeapHeader` (`packed struct(u8) { marked, frozen, _pad: u6 }`).

Exit criterion for 1.1: unit tests demonstrate `Value.initInteger(42)`
round-trips through `tag()` correctly, and `encodeHeapPtr(.string, ...)`
produces a value whose `tag()` reads back as `.string`.

## Open questions / blockers

(none)

## Notes for the next session

- `/continue` slash command is wired (`.claude/commands/continue.md`).
  Invoke it when starting a new session and the user says "続けて" /
  "resume" / similar.
- After 1.1 lands as a source commit, **do not write the doc immediately**
  — keep going with 1.2, 1.3, … as small commits, then one
  `docs/ja/0004-phase-1-runtime-foundations.md` covering all of Phase 1
  Layer-0 work when it makes a coherent story (or split as makes sense).
