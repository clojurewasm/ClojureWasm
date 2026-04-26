# Session handover

> Read this at session start. Update at session end (1–2 lines).
> Mutable, current-state only. Authoritative plan is `.dev/ROADMAP.md`.

## Current state

- **Phase**: Phase 2 IN-PROGRESS (2.1, 2.2 done; 2.3 next).
- **Branch**: `cw-from-scratch` (long-lived; v0.5.0-derived).
- **Last paired commit**: `docs(ja): 0007 — phase-1-runtime-foundations`
  (covers Phase-1 source commits 8b487f9..04476ac).
- **Build**: 107 tests passing (`zig build test`); `zone_check --gate` green.

## Unpaired source commits awaiting a doc

- `91feef0` feat(runtime): land dispatch + Runtime + Env skeletons together
- `07d5c34` refactor(runtime): promote KeywordInterner to rt-aware (mutex via rt.io)

## Next task

`§9.4 / 2.3` — `src/runtime/env.zig`: flesh out the Phase-2.1
skeleton with `Namespace`, `Var` (root binding + dynamic / macro /
private flags), `findNs` / `findOrCreateNs`, the threadlocal
`current_frame` binding stack, and `(refer src dst)`-style helpers
the bootstrap will need for `(refer 'rt)` into `user/`.

Exit criterion for 2.3: unit tests cover (a) defining a Var via a
namespace and resolving it back, (b) `current_frame` push / pop
behaving like a stack, (c) `referAll(rt_ns, user_ns)` exposing rt's
mappings under user/ without copying the Vars themselves.

## Open questions / blockers

(none)

## Notes for the next session

- Skill `continue` (`.claude/skills/continue/SKILL.md`) handles "続けて"
  / "/continue" / "resume". It auto-triggers on those phrases.
- Skill `code-learning-doc` defines the doc-commit pairing; the gate
  `scripts/check_learning_doc.sh` enforces it.
- Skill `audit-scaffolding` runs at every Phase boundary or every ~10
  ja docs to catch staleness / bloat / drift.
- After 1.1 lands as a source commit, **do not write the doc immediately**
  — keep going with 1.2, 1.3, … as small commits, then one
  `docs/ja/00NN-phase-1-runtime-foundations.md` (next available index)
  covering all of Phase 1 Layer-0 work when it makes a coherent story.
