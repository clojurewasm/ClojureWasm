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

| Path                                                    | What it is                            |
|---------------------------------------------------------|---------------------------------------|
| `~/Documents/MyProducts/ClojureWasm/`                   | ClojureWasm v1 (89K LOC, v0.5.0)      |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/` | Previous redesign attempt (Phase 1+2) |
| `~/Documents/OSS/clojure/`                              | Upstream Clojure JVM source           |
| `~/Documents/OSS/babashka/`                             | Babashka (SCI-based)                  |
| `~/Documents/OSS/zig/`                                  | Zig stdlib source                     |

## Language policy

Public project. **English by default** for code, comments, identifiers,
commit messages, README, ROADMAP, ADRs, `.dev/`, `.claude/`, all
configuration. **Japanese** for chat replies and `docs/ja/learn_clojurewasm/NNNN_*.md`
learning narratives.

Don't mix Japanese into English docs. In `docs/ja/`, body is Japanese;
code blocks keep their original English identifiers.

The chat-reply-in-Japanese rule is enforced by the project output style
[`.claude/output_styles/japanese.md`](.claude/output_styles/japanese.md)
(activated via `outputStyle: "Japanese"` in `.claude/settings.json`)
plus a SessionStart hook that re-injects the directive on every session.
Even with a slash command (e.g. `/continue`) as the very first input,
turn 1 must be Japanese.

## Working agreement

- TDD: red → green → refactor.
- **Step 0 (Survey) before each task**: an Explore subagent surveys
  the textbook codebases (v1, v1_ref, Clojure JVM, Babashka, Zig
  stdlib) and lands a 200–400 line note in `private/notes/`. See
  `.claude/rules/textbook_survey.md` for guardrails (cite ROADMAP
  principles before adopting an idiom; always note one DIVERGENCE).
- After each task, write a 5-minute per-task note from hot context
  (`private/notes/<phase>-<task>.md`, gitignored).
- `bash test/run_all.sh` must be green **on both Mac (host) and
  OrbStack Ubuntu x86_64** before every commit. The Linux run is
  `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` (Bash
  timeout ≥ 600s for cold builds). Setup: [`.dev/orbstack_setup.md`](.dev/orbstack_setup.md).
  Don't bypass hooks.
- Commit at the natural granularity of code changes; chapters
  (`docs/ja/learn_clojurewasm/NNNN_*.md`) are written **per concept** at phase
  boundaries — see skill `code_learning_doc` for the two-cadence flow.
- Subagent fork is the default for: Step 0 surveys, large test logs
  (>200 lines), cross-codebase searches (>5 files), phase-boundary
  audit / simplify / security-review fan-out. Stay in main only for
  small in-context edits.
- Pushing to `cw-from-scratch` requires explicit user approval.
- ROADMAP corrections follow the four-step amendment in
  [`ROADMAP §17`](.dev/ROADMAP.md#17-amendment-policy): edit in place
  as if it had always been so, open an ADR, sync `handover.md`,
  reference the ADR in the commit. Quiet edits are forbidden.
- `private/` is gitignored agent scratch (per-task surveys + notes,
  audit reports, the user's own brainstorming dumps). It is **not
  authoritative** — audit and resume procedures do not read it as
  load-bearing. If a `private/` proposal matters, promote it to
  ROADMAP / ADR / `docs/ja/` / `handover.md` (all tracked in git);
  otherwise let it stay scratch.

## Skills (the runnable procedures)

These hold the canonical procedures; CLAUDE.md only points to them.

- **`code_learning_doc`** — two-cadence Japanese learning material:
  per-task notes (private, gitignored) and per-concept chapters
  (`docs/ja/learn_clojurewasm/NNNN_*.md`, gated). Templates: `TEMPLATE_TASK_NOTE.md` and
  `TEMPLATE_PHASE_DOC.md`. The chapters use predict-then-verify
  exercises (L1/L2/L3), Feynman prompts, and a checklist — they are
  textbook units, not a project diary.
- **`continue`** — resume procedure + per-task TDD loop (with Step 0
  Survey, Step 7 per-task note, Step 8 60% compact gate) + multi-agent
  Phase-boundary review chain. Auto-triggers on "続けて" / "/continue"
  / "resume". **Fully autonomous from invocation**. Stops only for
  `git push`, ambiguous test failure, audit `block` finding, or an
  ADR-level design decision.
- **`audit_scaffolding`** — periodic audit for staleness, bloat, lies,
  and false positives across the tracked scaffolding (CLAUDE.md,
  `.dev/`, `.claude/`, `docs/`, `scripts/`). Auto-invoked by
  `continue` at every Phase boundary; can also be run on demand.

The Phase-boundary review chain (auto-run by `continue` when a Phase
closes) fans out under multiple subagents to: audit_scaffolding,
built-in `simplify` on the phase diff, built-in `security-review` on
unpushed commits, and outstanding chapter writing — all in parallel.

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
