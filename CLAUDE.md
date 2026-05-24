# ClojureWasm

A Clojure runtime written in Zig 0.16.0.

> Project memory loaded by Claude Code on every session. Keep it short.
> Detailed plans live in `.dev/ROADMAP.md`. Skills hold runnable procedures.

## Project spirit (top priority, governs everything below)

**The finished form's cleanliness wins.** Shipping fast and avoiding
rework are second-tier. Pre-built roadmaps and ADRs exist precisely
to minimise rework, but when they collide with "what the final shape
should look like", the final shape wins and the plan is amended in
place (ROADMAP §17). This applies to:

- **Big surgery is welcome** when design tighting-up exposes something
  the original plan missed. The autonomous loop must not hesitate at
  depth-3 / depth-4 revisions (`.dev/principle.md`).
- **Skeleton-then-rewrite is endorsed** (per `permanent_noop_forbidden`)
  but **excessive skeletons are a smell** (per the Smallest-diff bias
  smell). Each skeleton must shrink the final-form rewrite, not enlarge
  it.
- **Reservations (ADR numbers, NaN-box slots, debt rows promising
  future ADRs) are memos, not contracts.** Obeying a reservation
  because "it is reserved" is a smell (Reservation-as-bias smell,
  `.dev/principle.md`). ADR numbers are time-ordered (`max + 1` at
  issue time); slots / rows are reshuffled when the final form needs
  it.
- **Progress pressure does not override the smell sensor.** "Let me
  finish this task and come back" rarely comes back (Progress-pressure
  smell). Stop, surgery, resume.

This section is short on purpose. The mechanism lives in
[`.dev/principle.md`](.dev/principle.md) (Bad Smell catalogue + four
depths of revision + three questions to picture the finished form).
**User-declared invariants** the loop must treat as fact even when
ROADMAP / ADR text reads differently live in
[`.dev/project_facts.md`](.dev/project_facts.md) (F-001 zwasm v2
unavoidable, F-002 finished-form wins, F-003 deferral on
structural plans, F-004 NaN-box 64-slot, F-005 numeric tower
JVM-surface, F-006 GC strategy, F-007 chapter cadence dormant
permanently, F-008 zwasm v2 spec review — read this file when in
doubt).

### Priority order (the loop obeys this chain top-down)

1. **`project_facts.md`** — user-declared invariants, treated as
   project law. The loop **never amends an F-NNN on its own**;
   amendments require user direction in chat + a Revision history
   entry on the affected F-NNN.
2. **ROADMAP** — engineering plan + Phase order.
3. **ADRs + rules** — implementation decisions, amendable by the
   loop autonomously (depth 2-4 per principle.md).
4. **principle.md heuristics** — smell sensors, depth selection.
5. **AI judgement** — fills in everything the above leave open.

When two levels conflict, the higher level wins, and the lower
level is edited to align. Never the reverse. In particular,
treating an F-NNN as "informational" / "tie-breaker" /
"recommendation" is the **Smallest-diff bias smell** and is
forbidden.

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
  (v0.5.0). All work happens here. **Never push to `main`**. Every
  commit on `cw-from-scratch` is followed immediately by
  `git push origin cw-from-scratch` in the same Step 6 — commits do
  not accumulate locally.
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
configuration. **Japanese** for chat replies, `private/notes/<task>.md`
per-task notes, and (when re-activated) `docs/ja/learn_clojurewasm/NNNN_*.md`
learning narratives. The per-chapter cadence is currently **dormant**
per ADR-0025; existing chapters live read-only under
[`docs/ja/archive/`](docs/ja/archive/).

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
- Commit at the natural granularity of code changes. The per-concept
  chapter cadence (`docs/ja/learn_clojurewasm/NNNN_*.md`) is **dormant**
  per ADR-0025 until a resumption ADR fires; only the per-task notes
  half of the `code_learning_doc` skill is active.
- Subagent fork is the default for: Step 0 surveys, large test logs
  (>200 lines), cross-codebase searches (>5 files), phase-boundary
  audit / simplify / security-review fan-out. Stay in main only for
  small in-context edits.
- **Commit and push are one atomic Step 6** on `cw-from-scratch`:
  after the gate is green, `git commit` is followed immediately by
  `git push origin cw-from-scratch`. Local commits never accumulate
  unpushed — leaving them stacked invites a "should I push?"
  decision point that does not exist. Pushing to `main` is
  forbidden.
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
After `/continue` or session resume, run the per-task TDD loop.
The only thing that ends a session is the user explicitly asking
for it (§ The only stop). Everything else — task boundaries,
phase boundaries, smell triggers, ADR-level decisions, gate
failures under investigation — is handled in-flight. Do **not**
pause between tasks.

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
dissolved. **At a Phase entry** (the §9.<N> task list is about to
open), additionally read every row whose Status names the entering
phase (`Phase N entry` / `Phase N target` / `Phase N+ ...`) — these
are the structural-imagination outputs from earlier sessions that
the current Phase owner is meant to resolve.

**Step 1 — Plan**
One sentence in chat: the smallest failing test that captures the
next behaviour. Then **re-read `.dev/principle.md` and apply the
Bad Smell sensor** to the plan. If the plan touches any **structural
plan** (reservation table / directory or file structure / responsibility
separation / dependency graph), additionally apply the **Structural
imagination phase** from `principle.md` — imagine the full Phase 5-20
horizon, record gaps as debt rows scheduled at the owning Phase
entry, and **defer the structural decision to that owner**; do not
resolve here. If something feels off, adjust before Step 2.

**Step 1a — Phase reading list** (every Phase entry)
Read in order: `.dev/handover.md`, **`.dev/project_facts.md`**
(user-declared invariants the loop must treat as fact, even when
ROADMAP / ADR text admits other readings), `.dev/ROADMAP.md`
§9.<N> placeholder (Entry ADRs / **Entry debts** / Reference /
Skeletons to activate / Deliverables / Final activation step),
each ADR listed in the placeholder's "Entry ADRs:" line
**including the Phase N+ migration note section AND every
Revision history amendment if present** (this is where
existing-code rewrite scope and inter-Phase corrections are
narrated per §A25), each `D-NNN` debt row listed in the
placeholder's "Entry debts:" line (full row text in
`.dev/debt.md`), `compat_tiers.yaml` entry for the function, and
the JVM Clojure source (`~/Documents/OSS/clojure/`) for the
function.

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

**Step 6 — Source commit + push (atomic, smell-audited)**

Before staging:

1. Re-read the Bad Smell catalogue in `.dev/principle.md`.
2. Self-audit the staged diff against the catalogue (about a
   minute, no checklist — apply the sensor).
3. If a smell triggers, choose depth 1-4:
   - depth 1: add a one-line note in the commit message.
   - depth 2-4: land the ADR amendment / new ADR / `debt.md` row
     / `private/notes/` entry **autonomously**. Before drafting
     the ADR, **fork a `general-purpose` subagent with fresh
     context as Devil's advocate**. Brief the subagent with the
     decision under consideration **AND the active F-NNN
     constraints** (paste in or link to project_facts.md). Ask
     for 3 alternative shapes within the F-NNN envelope (one
     smallest-diff, one finished-form-clean, one "wildcard"
     within the constraints). **Subagent is instructed: "do NOT
     propose alternatives that violate any F-NNN; if the only
     finished-form-clean option requires violating an F-NNN,
     record that finding as the leading entry of Alternatives
     considered so the main loop sees it, but do not ask the loop
     to halt — F-NNN amendment is a user action".** Reflect the
     subagent's output verbatim into the ADR's "Alternatives
     considered" section before stamping `Status: Proposed →
     Accepted`. Commits the doc change first, then commits +
     pushes the source separately. No external review gate for
     ADR — ADR history (plus the Devil's-advocate output embedded
     in it) is the rationale record. If the subagent surfaces a
     would-violate-F-NNN finding, the main loop records it,
     selects the best F-NNN-compliant shape, and continues.

Then:

4. `git add` source files **and** `bench/quick_baseline.txt`
   (gate-generated observability log; default to include in
   source-bearing commits so number-changes line up with the
   source diff that caused them — see policy note below).
   Then `git commit` with **a two-line message shape**:
   ```
   <type>(<scope>): <one line summary>
   
   Smell-audited: <depth 0-4>: <one-line summary of audit outcome>
   <optional further body>
   ```
   `Smell-audited:` is **mandatory** on every commit that stages
   source-bearing files (`src/**/*.zig`, `build.zig`,
   `build.zig.zon`, `.dev/decisions/NNNN_*.md`). It records that
   Step 6's self-audit was actually performed. The pre-commit gate
   auto-aligns Markdown tables; only genuine table-syntax errors
   block.

   **`bench/quick_baseline.txt` commit policy** (added 2026-05-24
   after the user audit): the file is auto-appended by `bench/quick.sh`
   on every gate run. Treat it as source-coupled telemetry:
   - **Source-bearing commit**: include `bench/quick_baseline.txt`
     in the same commit (= numbers line up with the source diff
     that may have caused them).
   - **Doc-only / chore commit**: do NOT include (= the numbers
     have no source explanation to anchor against).
   - **Phase boundary**: if doc-only commits left bench deltas
     dangling, the Phase boundary review chain (continue skill)
     sweeps them into one `bench: accumulated samples through
     <phase>` commit.
5. `git push origin cw-from-scratch` runs immediately on the
   commit's success. **The `scripts/check_smell_audit.sh` PreToolUse
   hook physically blocks pushes that include any source-bearing
   commit missing a `Smell-audited:` line.** Re-audit, amend the
   commit message, push again. Push is not optional and not
   deferred.

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

### The only stop

**One condition: the user explicitly asks the loop to stop.**

That is it. There are no other stop conditions. Specifically:

- Task boundary, region boundary, cluster boundary, commit
  boundary, Phase boundary — none of these end the session. Each
  rolls straight into the next unit of work.
- Bad-Smell trigger (any depth, any frequency) — does not stop.
  It authorises **interrupt-style investigation and surgery** on
  the spot (see "Smell triggers are interrupts, not stops" below).
- ADR-level decision surfacing — does not stop. The AI drafts +
  accepts the ADR inline ("ADR-level designs are handled inline"
  below).
- Test failure / gate red — does not stop. Diagnose and fix; the
  loop is responsible for getting back to green, not for handing
  off.
- Long-running work, large diffs, big context — do not stop.
  Auto-compaction is transparent; size is never the reason.

A user "stop" directive applies to **the session in which it was
issued**. It does not carry across to the next session — the next
`/continue` (or any automated re-invocation) resumes the loop
under this rule unchanged.

### Smell triggers are interrupts, not stops

When the Bad Smell sensor (`.dev/principle.md`) fires, the loop
**interrupts the current activity and investigates without
compromise**. The investigation may be a one-line commit note
(depth 1), an ADR amendment (depth 2), a new ADR (depth 3), or a
Supersedes-chain rewrite (depth 4) — chosen per the sensor's
read, not per a frequency counter. Multiple smell triggers in one
cycle just mean multiple interrupts; they do not accumulate into
a stop. After each interrupt is resolved — at depth that matches
what the sensor surfaced — the loop returns to the per-task TDD
flow and continues.

The discipline is "do not defer the surgery; do not narrow the
investigation to fit the task budget; do not let momentum override
the sensor." Quality work is *how* the loop runs, not a reason to
hand off.

### ADR-level designs are handled inline

When a design choice surfaces that would historically be called
"ADR-level" (tier shift, scope change, principle deviation,
load-bearing structural choice), the AI handles it inline. It
gathers the "should-be" materials itself — alternatives,
trade-offs, references to existing ADRs — drafts the ADR with
`Status: Proposed → Accepted` in the same cycle, fills Affected
files / Consequences, lands the ADR commit, and proceeds with the
source change. Rationale survives in the ADR's history; the loop
does not need an external accept gate. Step 6's depth 2-4 branch
is the runway for this.

**Devil's-advocate subagent is mandatory at depth ≥ 2.** Before
stamping `Status: Proposed → Accepted`, fork a `general-purpose`
subagent with **fresh context** and brief it:

> "Devil's advocate this ADR. The active F-NNN constraints from
> `.dev/project_facts.md` are: [paste]. Produce 3 alternative
> shapes **within those constraints** (one smallest-diff, one
> finished-form-clean, one wildcard); for each, name what it
> does better than the current draft and what it breaks. Do NOT
> propose alternatives that violate any F-NNN; if the only
> finished-form-clean option requires violating an F-NNN, say
> so explicitly — record that finding as the leading entry of
> Alternatives considered so the main loop sees it, but do not
> ask the loop to halt."

The subagent's output is reflected verbatim into the ADR's
"Alternatives considered" section. This counters goal-drift /
instruction centrifugation by sourcing the alternatives from a
context without the main loop's accumulated momentum. The
subagent's recommendation is **not binding** within the F-NNN
envelope — the main loop still chooses — but the alternatives
must appear in the ADR. **Outside the F-NNN envelope**, a
"would-violate-F-NNN" finding does not stop the loop; the main
loop records the finding, picks the best F-NNN-compliant shape,
and continues. (If the user wants F-NNN itself amended, that is
a user action per `project_facts.md`'s amendment rule.)

The phrases "this needs human judgement" / "cannot be
self-decided" / "user touchpoint required" / "halt and surface"
are forbidden framings in the autonomous loop. If the choice is
between candidate designs, the AI picks one (finished-form first,
smallest-diff as the secondary tiebreaker per F-002), records the
rejected alternatives in the ADR's "Alternatives considered"
section, and continues.

## Skills (the runnable procedures)

These hold the canonical procedures; CLAUDE.md only points to them.

- **`code_learning_doc`** — Japanese learning material skill.
  **DORMANT per ADR-0025**: only the per-task notes half is active
  (Step 7 writes `private/notes/<task>.md` from hot context). The
  per-concept chapter half (`docs/ja/learn_clojurewasm/NNNN_*.md`) is
  suspended; the pre-commit pairing gate is a no-op; existing chapters
  live under [`docs/ja/archive/`](docs/ja/archive/). A future resumption
  ADR re-activates the chapter cadence; until then the templates
  (`TEMPLATE_TASK_NOTE.md` / `TEMPLATE_PHASE_DOC.md`) are preserved
  for that day.
- **`continue`** — resume procedure + per-task TDD loop (Step 0
  Survey → Step 7 per-task note → next task's Step 0) + multi-agent
  Phase-boundary review chain (audits run, then loop continues into
  §9.<N+1>). Auto-triggers on "続けて" / "/continue" / "resume".
  **Fully autonomous from invocation**. The only thing that ends a
  session is the user explicitly asking for it (see § The only
  stop).
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
