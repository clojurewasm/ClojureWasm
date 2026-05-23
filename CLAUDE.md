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
  (v0.5.0). All work happens here. **Never push to `main`**. Push to
  `cw-from-scratch` freely after green gate; no per-commit approval
  needed.
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
- **Step 0 (Survey) before each task**: a `general-purpose` subagent
  surveys the textbook codebases (v1, v1_ref, Clojure JVM, Babashka,
  Zig stdlib) and lands a 200–400 line note in `private/notes/`.
  `general-purpose` (not the read-only `Explore`) is required so the
  subagent can write the survey note itself. See
  `.claude/rules/textbook_survey.md` for guardrails (cite ROADMAP
  principles before adopting an idiom; always note one DIVERGENCE).
- After each task, write a 5-minute per-task note from hot context
  (`private/notes/<phase>-<task>.md`, gitignored).
- `bash test/run_all.sh` must be green **on both Mac (host) and
  OrbStack Ubuntu x86_64** before every commit. The Linux run is
  `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'` (Bash
  timeout ≥ 600s for cold builds). Setup: [`.dev/orbstack_setup.md`](.dev/orbstack_setup.md).
  Don't bypass hooks. The runner includes the zlinter `no_deprecated`
  gate on Mac only (ADR-0003) — Linux skips it because OrbStack
  runs are network-free.
- Commit at the natural granularity of code changes; chapters
  (`docs/ja/learn_clojurewasm/NNNN_*.md`) are written **per concept** at phase
  boundaries — see skill `code_learning_doc` for the two-cadence flow.
- Subagent fork is the default for: Step 0 surveys, large test logs
  (>200 lines), cross-codebase searches (>5 files), phase-boundary
  audit / simplify / security-review fan-out. Stay in main only for
  small in-context edits.
- Pushing to `cw-from-scratch` is free after green gate (no per-commit
  user approval). Pushing to `main` is forbidden.
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

## Autonomous Workflow

**Default mode: continuous autonomous execution.**
After `/continue` or session resume, run the per-task TDD loop
until a stop condition fires. Do **not** pause between tasks.

### Loop: Step 0 → 7 → next task's Step 0

After Step 7 (per-task note), **immediately start the next task's
Step 0**. Do not summarize, do not ask for confirmation. The next
task starts now. Auto-compaction handles context size transparently;
no agent action is needed.

**Step 0 — Survey** (subagent: `general-purpose`, default mode
"medium")
Survey the related codebase per `.claude/rules/textbook_survey.md`.
`general-purpose` (not the read-only `Explore`) is required so the
subagent writes the survey note directly. Skip only when the task
is a clear continuation (refactor / rename / doc-only). Output
lands in `private/notes/<phase>-<task>-survey.md`.

**Step 0.5 — Debt sweep**
Read `.dev/debt.md`. For each row whose `Last reviewed > 14 days
ago`, re-evaluate the Barrier predicate. Flip Status if the barrier
dissolved.

**Step 1 — Plan**
One sentence in chat: the smallest failing test that captures the
next behaviour. Then **re-read `.dev/principle.md` and apply the
Bad Smell sensor** to the plan. If something feels off, adjust
before Step 2.

**Step 1a — Phase reading list** (every Phase entry)
Read in order: `.dev/handover.md`, `.dev/ROADMAP.md` §9.<N>
placeholder (Entry ADRs / Reference / Skeletons to activate /
Deliverables / Final activation step), each ADR listed in the
placeholder's "Entry ADRs:" line **including the Phase N+ migration
note section if present** (this is where existing-code rewrite
scope is narrated per §A25), `compat_tiers.yaml` entry for the
function, and the JVM Clojure source
(`~/Documents/OSS/clojure/`) for the function.

**Step 2 — Red**
Write the failing test (Edit / Write). Run; confirm red.

**Step 3 — Green**
Minimal code to pass. Resist over-design; the next refactor pass
is cheap.

**Step 4 — Refactor**
Structural improvements only, while green. Then **re-read
`.dev/principle.md` and apply the Bad Smell sensor to the
Green → Refactor diff**. If a smell surfaced, choose depth 1-4
per principle.md and act before commit.

**Step 5 — Test gate** (Mac + Ubuntu x86_64 in parallel)

Run both in a single message with two parallel Bash tool calls:

- `bash test/run_all.sh` (Mac host, `aarch64-darwin`)
- `orb run -m my-ubuntu-amd64 bash -c 'bash test/run_all.sh'`
  (Linux `x86_64`, Bash timeout ≥ 600000 ms for cold builds)

Both must be green. If either output exceeds ~200 lines, delegate
to a Bash subagent and ask for "pass/fail + first failure only".

**Step 6 — Source commit**

Before staging:

1. Re-read the Bad Smell catalogue in `.dev/principle.md`.
2. Self-audit the staged diff against the catalogue (about a
   minute, no checklist — apply the sensor).
3. If a smell triggers, choose depth 1-4:
   - depth 1: add a one-line note in the commit message.
   - depth 2-4: hold the commit. Land the ADR amendment / new
     ADR / `debt.md` row / `private/notes/` entry first, then
     commit the source separately.
4. `git add` source files; `git commit -m "<type>(<scope>):
   <one line>"`. The pre-commit gate auto-aligns any Markdown
   tables that drifted and re-stages the fix transparently;
   only genuine table-syntax errors block.

**Step 7 — Per-task note** (written from hot context)

Copy `.claude/skills/code_learning_doc/TEMPLATE_TASK_NOTE.md` to
`private/notes/<phase>-<task>.md`. Fill in: 一行サマリ / 詰まった
ポイント (1-3 個) / 教科書との対比 (Step 0 survey の要約) /
設計判断 / 章を書くときに必ず触れる点. Gitignored. Then immediately
begin the next task's Step 0.

### When the current phase's task queue empties

When the active phase's §9.<N> task list has no remaining `[ ]`
rows:

1. Check `.dev/handover.md` "Next Phase Queue" — if populated,
   promote those entries to §9.<N+1>'s task table.
2. Otherwise: read `.dev/ROADMAP.md` Phase tracker → find the
   first PENDING phase → read **only that phase's placeholder
   section** in §9.<N+1>. The placeholder lists entry ADRs,
   reference sections in `private/JVM_TO_ZIG.md`, and skeletons
   to activate from earlier phases.
3. Expand §9.<N+1> inline: mirror the §9.6 structure (table of
   `[ ]` task rows + Exit criterion). Pull task content from the
   listed entry ADRs and reference sections; size each row so it
   is one to three TDD cycles.
4. Update the Phase tracker: mark current phase DONE, next phase
   IN-PROGRESS.
5. Commit alone: `git commit -m "roadmap: open Phase <N+1> task list"`.
6. Proceed to §9.<N+1>.1 Step 0.

### Stop only when (closed list)

Three conditions, exhaustive:

1. **User explicitly requests stop** (any direct instruction).
2. **ADR-level decision required that cannot be self-decided** —
   tier shift, scope change, principle deviation, or
   `audit_scaffolding` `block` finding that demands human judgement.
3. **Physically blocked** — build broken with no identifiable root
   cause, or test failure that cannot be diagnosed after honest
   investigation.

Anything outside these three is continued through. The loop's
quality discipline lives in `.dev/principle.md` (Bad Smell sensor,
depth 1-4 judgement) and is applied per cycle — quality is a *how*,
not a stop condition.

This list intentionally avoids enumerating non-stop reasons. Closed
stop conditions + open continue is the design.

## Skills (the runnable procedures)

These hold the canonical procedures; CLAUDE.md only points to them.

- **`code_learning_doc`** — two-cadence Japanese learning material:
  per-task notes (private, gitignored) and per-concept chapters
  (`docs/ja/learn_clojurewasm/NNNN_*.md`, gated). Templates: `TEMPLATE_TASK_NOTE.md` and
  `TEMPLATE_PHASE_DOC.md`. Chapters are **pure exposition** — narrative
  concept sections, design-alternatives table, "Try it" snippet,
  textbook comparison. No exercises, predict-then-verify, L1/L2/L3,
  Feynman, or checklists. They are textbook units, not a project diary.
- **`continue`** — resume procedure + per-task TDD loop (Step 0
  Survey → Step 7 per-task note → next task's Step 0) + multi-agent
  Phase-boundary review chain (audits run, then loop continues into
  §9.<N+1>). Auto-triggers on "続けて" / "/continue" / "resume".
  **Fully autonomous from invocation**. Stops only per the closed
  3-condition list in § Autonomous Workflow.
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

## Data sources (Phase 4 entry additions)

- [`compat_tiers.yaml`](compat_tiers.yaml) — authoritative Tier A / B /
  C / D classification per var, special form, and host class. Read by
  test runner, REPL error message, and future `cljw --list-vars`. See
  ADR-0013 for the Tier D rationale.
- [`.dev/debt.md`](.dev/debt.md) — row-level debt ledger. `continue`
  skill Step 0.5 sweeps this on every resume. See ROADMAP §A13.
- [`.dev/reference_clones.md`](.dev/reference_clones.md) — explicit
  usage purpose for `additionalDirectories` paths.
- [`.dev/lessons/INDEX.md`](.dev/lessons/INDEX.md) — observational
  learnings, distinct from load-bearing ADRs.

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — authoritative mission, principles,
  phase plan. **Single source of truth**; if anything in this file
  conflicts with the roadmap, the roadmap wins.
- [`.dev/handover.md`](.dev/handover.md) — short, mutable, current state.
  Framing per [`.claude/rules/handover_framing.md`](.claude/rules/handover_framing.md)
  (≤ 100 lines; driving doc, not session log).
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing decisions).
  Phase 4 entry batch: ADR-0004 through ADR-0024 (Day-1 enums, dual
  backend, Wasm defer, TypeDescriptor, protocol unify, heap-only lock,
  STM Tier A, host extension, ValueTag, Tier D permanent, UTF-8,
  io_interface, file size smell, Allocator strategy, error catalog
  SSOT, crash policy, ADR governance, test taxonomy, differential
  wiring, comptime stub, scan framework + run_step).
