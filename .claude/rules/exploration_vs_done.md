---
paths:
  - "**"
---

# Exploration vs Done

## Rule

cw v1 has two modes of work:

- **Exploration**: free-form. Tracked files are not yet touched.
  Scratch lives in `private/notes/`, REPL sessions, throwaway
  `.clj` files. The only rule is "don't break the working tree".
- **Done**: tracked. A change lands in `src/` / `.dev/` /
  `.claude/` / `scripts/` / `test/` / `bench/` / `docs/ja/` /
  `ARCHITECTURE.md` / `CLAUDE.md` / `compat_tiers.yaml`. Done
  requires the gate.

The transition from exploration to Done has explicit checkpoints.

## Why

- Exploration without freedom slows research (every grep wants to
  be a test).
- Done without a gate is how code rots (a half-rewritten module
  lands "to fix later").
- The boundary needs to be visible so the agent can self-locate
  ("am I in exploration or am I trying to land?").

Pollaroid `CLAUDE.md` L31-65 documents this discipline; cw v1
adopts the same shape with cw-specific gates.

## Done gate (every tracked-file landing)

Before staging a tracked file for commit:

1. **Build is green**: `zig build test` passes for source changes.
2. **Gate scripts pass**: `bash test/run_all.sh` passes
   (or the relevant subset via `--only`).
3. **ADR reference**: the change either implements an existing
   ADR row or carries its own ADR / amendment per ROADMAP §17.
4. **handover.md updated**: current state reflects the landing.
5. **Doc paired (if source-only commit)**: a chapter under
   `docs/ja/learn_clojurewasm/` lands within the chapter cadence
   per `code_learning_doc` skill.

If any of the five fails, the change is still exploration.

## Exploration freedom

Inside exploration mode:

- Multi-line `cljw -e '...'` calls, REPL evaluations, scratch
  `.clj` files outside `test/` are fine.
- `private/notes/<phase>-<task>.md` carries the work log.
- Subagent-generated drafts may live in `private/` until
  promoted.

Only when a finding stabilises into "this should land" does the
Done gate apply.

## How the agent self-locates

When in doubt, ask: "is this in a tracked path that
`git status` reports?" If yes, Done gate applies. If no
(private/, REPL, /tmp), exploration mode.

## Counter-examples

Don't stage a tracked file edit without running the gate
("just a docs typo" — still the gate applies, `md-table-align`
catches the formatting).

Don't keep tracked files in a half-rewritten state across multiple
commits without an explicit ADR amendment that says "Phase X part
1 lands here, part 2 in commit Y".

Don't promote a `private/notes/` finding to tracked text without
re-reading what tracked authority already says on the topic
(ADR / ROADMAP / rule).
