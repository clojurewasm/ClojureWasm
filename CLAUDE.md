# ClojureWasm

A Clojure runtime written in Zig 0.16.0.

> This file is the project memory loaded by Claude Code on every session.
> Keep it short. Detailed plans live in `.dev/ROADMAP.md`.

## Identity / Context (Claude Code: read first)

**Project name (in all docs and the published artifact): `ClojureWasm`.**
Binary name: `cljw`. Package name: `cljw`.

The working directory and a long-lived branch are intentionally named with
`from-scratch` because **this branch is a ground-up redesign of ClojureWasm
on top of the v0.5.0 git history**:

- **Working directory**: `~/Documents/MyProducts/ClojureWasmFromScratch/`
  — kept distinct from the existing `~/Documents/MyProducts/ClojureWasm/`
  reference clone.
- **Branch**: `cw-from-scratch` — long-lived. Branched from `main` (v0.5.0).
  All work happens here. **Never push to `main`.** Push to `cw-from-scratch`
  only with explicit user approval.
- **Git remote**: `git@github.com:clojurewasm/ClojureWasm.git` (the upstream
  ClojureWasm repository).

### Read-only reference clones (do not edit, do not commit from)

| Path                                                       | What it is                                  | Use as                |
|------------------------------------------------------------|----------------------------------------------|-----------------------|
| `~/Documents/MyProducts/ClojureWasm/`                      | ClojureWasm v1 (89K LOC, v0.5.0)             | Design reference      |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/`    | Previous redesign attempt (Phase 1+2)        | Implementation reference |
| `~/Documents/MyProducts/learn-clojurewasm-from-scratch/`   | Per-task tutorial markdown (separate repo)   | Historical only — new tutorials live in this repo's `docs/ja/` |
| `~/Documents/OSS/clojure/`                                 | Upstream Clojure JVM source                  | Semantics reference   |
| `~/Documents/OSS/babashka/`                                | Babashka (SCI-based)                         | Native-Clojure precedent |
| `~/Documents/OSS/zig/`                                     | Zig stdlib source                            | API reference         |

All editing and `git commit` happen in
`~/Documents/MyProducts/ClojureWasmFromScratch/` only.

## Language policy

This project is public.

- **English by default**: code, comments, identifiers, commit messages,
  README, ROADMAP, ADRs, `.dev/`, `.claude/`, all configuration.
- **Japanese**: chat replies (between user and Claude) and **commit-snapshot
  learning docs under `docs/ja/`**.

When updating any English doc, do **not** mix Japanese into it. When writing
a `docs/ja/NNNN-*.md`, body is Japanese; code blocks keep their original
English identifiers.

## Working agreement

- All code, comments, and commit messages in English.
- TDD: red → green → refactor.
- Run `bash test/run_all.sh` (or `zig build test`) before every commit.
  Do not bypass the hook.
- Commit at the natural granularity of code changes; do **not** inflate a
  single commit to also carry the narrative — that's what the doc commit
  is for (see "Commit pairing" below).

### Commit pairing: source commits → doc commit

Source-bearing commits (`src/**/*.zig`, `build.zig`, `build.zig.zon`,
`.dev/decisions/NNNN-<slug>.md` — `README.md` and `0000-template.md`
under `.dev/decisions/` are excluded) accumulate freely. When a unit of
work is ready to be told as one story, write a `docs/ja/NNNN-<slug>.md`
in a **separate** commit. The doc's `commits:` front-matter list cites
all source SHAs it covers.

```
commit N      feat(scope): step 1            # source only
commit N+1    refactor(scope): step 2        # source only
commit N+2    fix(scope): step 3             # source only
commit N+3    docs(ja): NNNN — title         # commits: [N, N+1, N+2]
```

The doc lands AFTER the source commits, so every SHA it cites is already
known — no "TBD then patch" cycle.

- **Skill / template**: [`.claude/skills/code-learning-doc/SKILL.md`](.claude/skills/code-learning-doc/SKILL.md)
- **Gate**: [`scripts/check_learning_doc.sh`](scripts/check_learning_doc.sh) (PreToolUse hook on Bash) blocks (a) commits that mix source and a doc, and (b) doc commits whose `commits:` list omits any unpaired source SHA since the previous doc.

## Iteration loop (resume / "続けて" procedure)

When you (Claude) start a new session and the user says "続けて" or
"resume" or anything that implies "pick up where we left off":

1. **Read** `.dev/handover.md` (if it exists) — this is the explicit
   session-to-session memo.
2. **Read** `.dev/ROADMAP.md` — find the IN-PROGRESS phase in §9 (or the
   first PENDING phase if none is in-progress). Inside that phase, find
   the first `[ ]` (incomplete) task.
3. **Inspect** `git log --oneline -10` for recent commits and any
   unpaired source commits (use `bash scripts/check_learning_doc.sh`'s
   logic mentally: walk back to the last `docs/ja/NNNN-*.md` commit).
4. **Summarise** to the user in 4–6 lines:
   - Phase (number + name)
   - Last commit (`git log -1 --format='%h %s'`)
   - Unpaired source commits (if any) — these need a doc next
   - Next task (number + name + exit criterion)
5. **Wait for user "go"** before starting TDD on the next task.
   (Do not start coding without confirmation; the user may want to
   adjust direction.)

A `/continue` slash command exists at `.claude/commands/continue.md`
that wraps this procedure for explicit invocation.

### Per-task TDD loop

1. **Plan** the smallest red test (1 sentence in chat).
2. **Red**: write the failing test.
3. **Green**: minimal code to pass.
4. **Refactor** while green.
5. `bash test/run_all.sh` must be green.
6. **Source commit**: `git add` only the source files; `git commit -m
   "<type>(<scope>): <one line>"`.
7. Repeat 1–6 as many times as the unit of work needs (the gate does
   not block).
8. **Doc commit**: when the story is ready, write
   `docs/ja/NNNN-<slug>.md` per the `code-learning-doc` skill; commit
   with `commits: [...]` listing every source SHA since the last doc.
9. **Update** `.dev/handover.md` with one line per session (current
   task, blocker if any).

## Layout

```
src/         Zig source
build.zig    Build script (Zig 0.16 idiom)
flake.nix    Nix dev shell pinned to Zig 0.16.0
.dev/        Design docs (English): ROADMAP, decisions, handover
docs/        Public docs. `docs/ja/` holds Japanese learning tutorials.
.claude/     Claude Code project settings, skills, commands, hooks
scripts/     Project scripts (gate, checks)
test/        Test entry point + future suites
```

## Build & test

```sh
zig build         # build
zig build test    # all tests
zig build run     # run executable (`cljw`)
zig fmt src/      # format
```

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — the authoritative mission, principles,
  phases, and success criteria. **Single source of truth**; if anything in
  this file conflicts with the roadmap, the roadmap wins.
- [`.dev/handover.md`](.dev/handover.md) — short, mutable, current session state.
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing decisions).
