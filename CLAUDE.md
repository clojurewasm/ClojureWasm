# ClojureWasm

A Clojure runtime written in Zig 0.16.0.

> Project memory loaded by Claude Code on every session. Keep it short.
> Detailed plans live in `.dev/ROADMAP.md`. Skills hold runnable procedures.

## Identity / Context (read first)

**Project name (in all docs and the published artifact): `ClojureWasm`.**
Binary name: `cljw`. Package name: `cljw`.

Working directory + branch are intentionally named with `from-scratch`
because **this branch is a ground-up redesign of ClojureWasm on top of
the v0.5.0 git history**:

- **Working directory**: `~/Documents/MyProducts/ClojureWasmFromScratch/`
  — distinct from the existing `~/Documents/MyProducts/ClojureWasm/`
  reference clone.
- **Branch**: `cw-from-scratch` — long-lived, branched from `main`
  (v0.5.0). All work happens here. **Never push to `main`**; push to
  `cw-from-scratch` only with explicit user approval.
- **Git remote**: `git@github.com:clojurewasm/ClojureWasm.git`.

### Read-only reference clones (do not edit, do not commit from)

| Path                                                       | What it is                                  |
|------------------------------------------------------------|----------------------------------------------|
| `~/Documents/MyProducts/ClojureWasm/`                      | ClojureWasm v1 (89K LOC, v0.5.0)             |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/`    | Previous redesign attempt (Phase 1+2)        |
| `~/Documents/OSS/clojure/`                                 | Upstream Clojure JVM source                  |
| `~/Documents/OSS/babashka/`                                | Babashka (SCI-based)                         |
| `~/Documents/OSS/zig/`                                     | Zig stdlib source                            |

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all
configuration. **Japanese** for chat replies and `docs/ja/NNNN-*.md`
learning narratives.

Don't mix Japanese into English docs. In `docs/ja/`, body is Japanese;
code blocks keep their original English identifiers.

## Working agreement

- TDD: red → green → refactor.
- `bash test/run_all.sh` must be green before every commit. Don't
  bypass hooks.
- Commit at the natural granularity of code changes; the doc commit
  carries the narrative (see skill `code-learning-doc`).
- Pushing to `cw-from-scratch` requires explicit user approval.

## Skills (the runnable procedures)

These hold the canonical procedures; CLAUDE.md only points to them.

- **`code-learning-doc`** — when to write `docs/ja/NNNN-*.md`, the
  template, and the gate's two rules. Single source of truth for
  commit pairing.
- **`continue`** — resume procedure for a new session ("続けて" /
  "/continue"). Includes the per-task TDD loop.
- **`audit-scaffolding`** — periodic audit of CLAUDE.md, .dev/,
  .claude/, docs/, scripts/ for staleness, bloat, lies, false
  positives. Runs at every Phase boundary or on user request.

## Layout

```
src/         Zig source
build.zig    Build script (Zig 0.16 idiom)
flake.nix    Nix dev shell pinned to Zig 0.16.0
.dev/        ROADMAP + handover + ADRs
docs/ja/     Japanese learning narratives
.claude/     settings, skills, rules
scripts/     gate, zone check
test/        unified runner + future suites
```

## Build & test

```sh
bash test/run_all.sh   # run everything
zig build run          # run executable (`cljw`)
zig fmt src/           # format
```

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — authoritative mission, principles,
  phase plan. **Single source of truth**; if anything in this file
  conflicts with the roadmap, the roadmap wins.
- [`.dev/handover.md`](.dev/handover.md) — short, mutable, current state.
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing decisions).
