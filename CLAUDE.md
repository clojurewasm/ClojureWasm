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
  learning docs under `docs/ja/`** (see workflow below).

When updating any English doc, do **not** mix Japanese into it. When writing
a `docs/ja/NNNN-*.md`, body is Japanese; code blocks keep their original
English identifiers.

## Working agreement

- All code, comments, and commit messages in English.
- One task = one commit. Never bundle unrelated changes.
- TDD: red → green → refactor.
- Run `zig build test` before every commit. Do not bypass hooks.

### Commit pairing: source commit → doc commit

Every source-bearing commit (`src/**/*.zig`, `build.zig`, `build.zig.zon`,
or `.dev/decisions/NNNN-<slug>.md` — `README.md` and `0000-template.md`
under `.dev/decisions/` are excluded) is **immediately followed** by a
separate commit that adds the paired `docs/ja/NNNN-<slug>.md` (Japanese,
sequenced). The pair forms the unit of progress.

```
commit N      feat(scope): ...           # source only
commit N+1    docs(ja): NNNN — ...       # docs/ja/NNNN-*.md only
```

Writing the doc *after* the source commit lets the doc's `commit:` front
matter reference the actual SHA — no "TBD then patch" cycle.

- **Skill / template**: [`.claude/skills/code-learning-doc/SKILL.md`](.claude/skills/code-learning-doc/SKILL.md)
- **Gate**: [`scripts/check_learning_doc.sh`](scripts/check_learning_doc.sh) runs as a `PreToolUse` hook on every Bash invocation. It blocks (a) any commit that mixes source and a learning doc, and (b) any commit that follows an unpaired source commit without supplying the doc.

The doc captures background, the code snapshot at that moment, the why,
and takeaways — material for a future technical book and conference talks.

## Layout

```
src/         Zig source
build.zig    Build script (Zig 0.16 idiom)
flake.nix    Nix dev shell pinned to Zig 0.16.0
.dev/        Design docs (English): ROADMAP, decisions, status, handover
docs/        Public docs. `docs/ja/` holds Japanese commit-snapshot tutorials.
.claude/     Claude Code project settings, skills, hooks
scripts/     Project scripts (gate, checks)
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
