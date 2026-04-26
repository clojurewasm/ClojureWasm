# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.

## Current state

- **Phase**: Phase 2 DONE; Phase 3 IN-PROGRESS (§9.5 expanded).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired commit**: `docs(ja): 0008 — phase-2-tree-walk-evaluator`
  (covers Phase-2 source commits 91feef0..7d9fe5f).
- **Build**: 176 tests passing (`zig build test`); `zone_check --gate`
  green; `test/e2e/phase2_exit.sh` green (3/3 CLI cases).
- **Phase-2 exit criterion**: `cljw -e "(let* [x 1] (+ x 2))"` → `3`
  and `cljw -e "((fn* [x] (+ x 1)) 41)"` → `42` ✓.

## Unpaired source commits awaiting a doc

(none — 0008 closes Phase 2)

## Next task

`§9.5 / 3.1` — `src/runtime/collection/string.zig`: heap-backed
String type. The Phase-1 Reader returns `.string` Form atoms, but
the Phase-2 analyzer treats them as `NotImplemented`. 3.1 lifts
them: a `String` heap struct (HeapHeader + len + bytes), a
`runtime.string.alloc(rt, bytes)` helper that registers via
`rt.trackHeap`, and an analyzer change so `.string` Forms become
`ConstantNode { value = string-Value }`.

Exit criterion for 3.1: `cljw -e "\"hello\""` reads, lifts, and
prints `"hello"` (with the surrounding quotes).

## Open questions / blockers

(none)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles "続けて"
  / "/continue" / "resume". It auto-triggers on those phrases.
- Skill `code-learning-doc` defines the doc-commit pairing; the gate
  `scripts/check_learning_doc.sh` enforces it.
- Skill `audit-scaffolding` runs at every Phase boundary or every ~10
  ja docs to catch staleness / bloat / drift.
- Phase-3 doc commit timing: aim for one `docs/ja/0009-*.md` covering
  all of Phase 3 once the exit criteria pass (~10 source commits).
  Don't write per-task docs.
- The 🔒 marker on Phase 4 means a fresh OrbStack x86_64 gate is due
  at the Phase-3 → Phase-4 boundary (re-run the same `orb run -m
  my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` invocation).
