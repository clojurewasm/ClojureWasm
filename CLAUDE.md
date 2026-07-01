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
permanently, F-008 zwasm v2 spec review, F-009
feature-implementation neutrality — read this file when in
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

This codebase is a ground-up redesign of ClojureWasm on top of the v0.5.0 git
history. On **2026-06-10 the redesign was merged into `main`** (an `-s ours`
merge superseding the v0.5.0 main + its libc hotfix; the `v0.5.0` tag is
preserved), and `main` is the working branch:

- **Working directory**: `~/Documents/MyProducts/ClojureWasm/`.
- **Branch**: `main` — the working branch. **All work happens on `main`**
  and every commit is followed immediately by `git push origin main` in the
  same Step 6 — commits do not accumulate locally.
- **Git remote**: `git@github.com:clojurewasm/ClojureWasm.git`.

### Read-only reference points (do not edit, do not commit from)

| Reference                                               | What it is                                                                                                                                                                                                                              |
|---------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| cw v0 — git tag `v0.5.0`                               | ClojureWasm v0 (89K LOC), the pre-redesign design reference. Its source is NOT in `main`'s tree (the `-s ours` merge kept the redesign tree), so reach it through git: `git worktree add ../cw-v0 v0.5.0`, or `git show v0.5.0:<path>`. |
| `~/Documents/MyProducts/ClojureWasmFromScratch_v1_ref/` | Previous redesign attempt (Phase 1+2), if present locally.                                                                                                                                                                              |
| `~/Documents/OSS/clojure/`                              | Upstream Clojure JVM source                                                                                                                                                                                                             |
| `~/Documents/OSS/babashka/`                             | Babashka (SCI-based)                                                                                                                                                                                                                    |
| `~/Documents/OSS/zig/`                                  | Zig stdlib source                                                                                                                                                                                                                       |

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
- **Per-commit = smoke**, not the full gate (ADR-0107 two-tier gate;
  the full e2e suite grew heavy, so "full every commit" is retired).
  `bash test/run_all.sh --smoke <changed-e2e-step>` (~tens of sec) green
  **on Mac (host)** authorises a source commit — including shared-code,
  because the smoke runs the full dual-backend diff oracle + every unit
  test. The **full gate batches** (run ALONE) at the ≤5-commit ceiling /
  Phase boundary / pre-tag. Prefer a **ReleaseSafe** binary (`zig build
  -Dwasm -Doptimize=ReleaseSafe` = the gate config, so it cache-hits) for
  manual behaviour probes; `-Dcpu=baseline` only for deploy artifacts.
  SSOT: [`.claude/rules/gate_cadence.md`](.claude/rules/gate_cadence.md).
  **Linux x86_64 is no longer per-commit** (ADR-0049, orphan / fan
  hazard): run `bash scripts/run_remote_ubuntu.sh` (→ `ubuntunote` SSH
  host) at Phase boundaries, before the v0.1.0 tag, and on demand.
  Don't bypass hooks. ubuntunote skips the Mac-only zlinter
  `no_deprecated` gate (ADR-0003), so a 1-PASS-count host diff is
  expected. Setup: [`.dev/ubuntunote_setup.md`](.dev/ubuntunote_setup.md).
- Commit at the natural granularity of code changes. The per-concept
  chapter cadence (`docs/ja/learn_clojurewasm/NNNN_*.md`) is **dormant**
  per ADR-0025 until a resumption ADR fires; only the per-task notes
  half of the `code_learning_doc` skill is active.
- Subagent fork is the default for: Step 0 surveys, large test logs
  (>200 lines), cross-codebase searches (>5 files), phase-boundary
  audit / simplify / security-review fan-out. Stay in main only for
  small in-context edits.
- **Commit and push are one atomic Step 6** on `main`:
  after the gate is green, `git commit` is followed immediately by
  `git push origin main`. Local commits never accumulate
  unpushed — leaving them stacked invites a "should I push?"
  decision point that does not exist.
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
Read `.dev/debt.yaml`. For each row whose `Last reviewed > 14 days
ago`, re-evaluate the Barrier predicate. Flip Status if the barrier
dissolved. **When opening a gap-area unit** (ROADMAP §9.0 / ADR-0142;
the phase-entry model is retired), additionally read every row whose
barrier names that gap area (`gap area I/II/III`) — these are the
draining rows that gap area owns. Any residual `Phase N` status string
is a not-yet-re-barriered row (R4 work, D-440); resolve it via the §9.0
phase-number→gap-area redirect.

**Quality-loop floor drain (post-M / F-010 operating mode).** The
post-M quality-elevation loop is a *repeatable* mode, not a Phase, so
its debt is anchored on a standing **`quality-loop floor: <category>`**
Barrier instead of a one-time Phase entry (see
`.dev/tech_debt_consolidation.md`). When self-selecting the next
quality-loop unit (per § The only stop's next-task rule), **first read
every open `quality-loop floor:` row and drain it EASIEST-FIRST (by
tractability, not value — 2026-06-25 decision), before opening a fresh
sweep category** — this makes the loop debt-driven so floor items cannot
silently rot (the failure mode the 2026-05-31 audit found). A correctness
floor row still preempts; otherwise drain the whole list, niche included. Re-run the 5-lens consolidation audit (D-175) at each Phase
boundary so new orphans are caught within one Phase.

**Step 0.6 — Re-laying against finished-form (main agent)**
The main agent (not a subagent) reads the survey output and
spends up to 30 minutes:
  1. Walk the plan's required-feature chain mentally; confirm the
     prerequisites the survey assumed are actually in place.
  2. Re-lay the plan against finished-form (F-NNN in
     `.dev/project_facts.md` + `.dev/structure_plan.md` + ROADMAP
     §9): does the survey's recommended shape land closer to the
     finished form, or is it a smallest-diff convenience that the
     finished-form owner would unwind?
  3. If the survey misses a prerequisite or proposes a
     smallest-diff bias path, **amend the survey in place** (the
     survey is not immutable — it is the loop's input, not its
     contract).
  4. If the re-laying surfaces a provisional behaviour the cycle
     will need to introduce, **fork a `general-purpose`
     Devil's-advocate subagent (mandatory, even at depth 1)**
     to enumerate finished-form-clean alternatives within the
     F-NNN envelope before committing to the provisional shape.
     The marker comment + `feature_deps.yaml` entry + `.dev/debt.yaml`
     row triad (per `.claude/rules/provisional_marker.md`) lands
     in the same commit as the provisional behaviour.

Step 0.6 is the discipline answer to "Step 0 surveys are only
~80% accurate; the remaining 20% surfaces in implementation".
Skip only when Step 0 itself was skipped (= the task is a
refactor / rename / doc-only change).

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

**Step 1a — Unit reading list** (at each gap-area unit's start)
The phase-entry/placeholder model is retired (ROADMAP §9.0 /
ADR-0142); read per **gap-area unit** instead. Read in order:
`.dev/handover.md`, **`.dev/project_facts.md`** (user-declared
invariants the loop must treat as fact, even when ROADMAP / ADR text
admits other readings), the relevant `.dev/ROADMAP.md` **§9.0 gap-area
section** (I Concurrency / II Wasm-edge-native / III VM-perf) — its
BUILT status + named gaps + the draining `D-NNN` rows — each ADR cited
there **including any Phase N+ migration note + every Revision history
amendment** (where existing-code rewrite scope + inter-unit corrections
are narrated per §A25), the full text of each cited `D-NNN` row (in
`.dev/debt.yaml`), the `compat_tiers.yaml` entry for the function, and
the JVM Clojure source (`~/Documents/OSS/clojure/`) for the function.

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

**Step 5 — Test gate** (Mac smoke per-commit; full gate batched; ubuntunote at boundaries)

Two-tier per ADR-0107 (full e2e is now heavy — never run it per commit
while batching). SSOT: [`.claude/rules/gate_cadence.md`](.claude/rules/gate_cadence.md).

- **Per commit = smoke**: `bash test/run_all.sh --smoke <changed-e2e-step>`
  (~tens of sec) — `zig build test` ×2 (the full F-012 diff oracle + all
  units) + zlinter + `build_cljw` + `corpus_regression` + the changed e2e
  step(s). Stamps `.dev/.smoke_pass`; authorises the commit (shared-code
  included) up to the ≤5 ceiling. **Do not block on it** — background it
  and keep moving. Manual behaviour checks use a **ReleaseSafe** binary
  (`zig build -Dwasm -Doptimize=ReleaseSafe` = the gate config), not the Debug default.
- **Batched full gate** (run ALONE): `bash scripts/run_gate.sh` reaps any
  orphan `run_all.sh` tree + PID-1-orphaned `cljw` probes, then `exec`s
  `timeout 300 bash test/run_all.sh` (writes `.dev/.gate_pass`; cadence
  hook unaffected; orphan-safe per
  [`.claude/rules/orphan_prevention.md`](.claude/rules/orphan_prevention.md)
  § Gate launcher + memory `premature-gate-notification`). Run it at the
  5-commit ceiling / Phase boundary / pre-tag — backgroundable as a
  look-ahead. On-demand reap without a gate: `bash scripts/run_gate.sh reap`.
  If a full gate fails on ONLY a non-code check (e.g. `check_debt_id_refs`),
  fix it + re-smoke — do NOT re-run the whole full gate.

If the output exceeds ~200 lines, delegate to a Bash subagent
and ask for "pass/fail + first failure only".

The Ubuntu x86_64 gate is **no longer per-commit** as of
ADR-0049 (orphan / fan hazard). Run it at Phase-boundary review
chains, before v0.1.0 tag, and on demand for feature branches:

- `bash scripts/run_remote_ubuntu.sh` (drives `ubuntunote` SSH
  host via `git fetch + reset --hard origin/main` +
  `nix develop --command bash test/run_all.sh`). Setup at
  `.dev/ubuntunote_setup.md`.

**Orphan-prevention discipline**: every
`Bash(run_in_background: true)` driving a long-running child
process MUST wrap with `timeout 600 …`. REPL-pipe-specific
hazard, `timeout`-not-propagating caveat for SSH / VM
boundaries, and counter-examples live in
[`.claude/rules/orphan_prevention.md`](.claude/rules/orphan_prevention.md)
(ADR-0049 § Context is the precedent; D-128 discharged).

**Step 6 — Source commit + push (atomic, smell-audited)**

Before staging:

1. Re-read the Bad Smell catalogue in `.dev/principle.md`.
2. Self-audit the staged diff against the catalogue (about a
   minute, no checklist — apply the sensor).
3. If a smell triggers, choose depth 1-4:
   - depth 1: add a one-line note in the commit message.
   - depth 2-4: land the ADR amendment / new ADR / `debt.yaml` row
     / `private/notes/` entry **autonomously**. Devil's-advocate
     subagent fork is mandatory at depth ≥ 2 — see § ADR-level
     designs are handled inline below for the canonical brief.
     Commit the doc change first, then commit + push the source
     separately. ADR history (including the embedded
     Devil's-advocate output) is the rationale record; no
     external accept gate.

Then:

4. `git add` the source files. (The `bench/quick_baseline.txt` auto-baseline
   was retired 2026-06-11 — the gate no longer runs `bench/quick.sh`; perf is
   measured on demand via `bench/compare_langs.sh` / `bench/run_bench.sh`.)
   Then `git commit` with the two-line shape:
   ```
   <type>(<scope>): <one line summary>

   Smell-audited: <depth 0-4>: <one-line summary of audit outcome>
   <optional further body>
   ```
   `Smell-audited:` is **mandatory** on every commit that stages
   source-bearing files (`src/**/*.zig`, `build.zig`,
   `build.zig.zon`, `.dev/decisions/NNNN_*.md`). Pre-commit gate
   auto-aligns Markdown tables; only genuine syntax errors block.
5. `git push origin main` runs immediately on the
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

### When the active work unit completes (gap-area model, ADR-0142)

The phase-queue model is **RETIRED** (ROADMAP §9.0 / ADR-0142): the
project is near-complete, so there is no "next PENDING phase
placeholder" to expand. Phases 9-14 are DONE; the remaining work lives
in three **gap areas** (I Concurrency-hardening / II Wasm-edge-native /
III VM-perf fusion→JIT) + a small genuinely-future bucket. When the
active unit's work runs low, the loop **self-selects** the next unit (it
never asks the user — see § The only stop's next-task rule):

1. Check `.dev/handover.md` "First task on resume" — if it names a
   concrete next unit, take it.
2. Otherwise self-select from the live `.dev/debt.yaml` `active:` rows
   (the Step 0.5 sweep surfaces them), **EASIEST-FIRST — by tractability,
   NOT by value** (user decision 2026-06-25; the standing snapshot +
   easiest→hardest drain order is `private/notes/2026-06-25-debt-drain-order.md`,
   refreshed from the live ledger). **Drain the WHOLE active list, niche /
   deferred / "low-value" rows INCLUDED — the goal is to eliminate 残件, so
   do NOT perpetually defer a row as "take-up-on-consumer".** A correctness /
   clj-parity floor still PREEMPTS (do it first if one is open), but otherwise
   ease — not value — sets the order. (F-002 finished-form still governs HOW
   each task is done — quality per task — but no longer the ORDER between tasks.)
   The genuinely-blocked Tier-4 rows (Tier-D needing a MAJOR/user nod, security
   forward-looking design, the paused perf campaign, recall/load-sensitive races,
   `.claude/`-edit-blocked) are the non-autonomous remainder — skip until their
   gate changes; everything else drains.
3. Size the unit at one-to-three TDD cycles; run the per-task loop
   (Step 0 → 7). **Update the ledger RELIABLY in the SAME cycle the work
   lands**: when a row's work completes, prepend a `DISCHARGED <date>` note to
   its status AND MOVE it from `active:` to `discharged:` (data-preserving text
   move — insert the block just before the trailing `conventions:` key, NOT at
   EOF; recipe in the 2026-06-25 audit commit); when you merely TOUCH a row whose
   status is partly stale, re-narrow it against code-truth. The ledger is the
   live SSOT — never let a done row rot in `active:`.

The genuinely-future bucket (ClojureScript→JS / C-FFI / broad-JIT,
§9.0) is distal and **not** self-selected absent a user nod. The
capability-matrix successor to this gap-area model is forward debt
**D-443** (open after the D-440 arc completes).

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
- **Next-task / direction ambiguity — does not stop, and is NEVER
  resolved by asking the user.** When the clean/obvious work runs
  low, the loop SELF-SELECTS the next unit (**EASIEST-FIRST debt drain,
  not value-first** — 2026-06-25 decision; drain the whole `active:` list
  including niche/deferred to eliminate 残件, updating the ledger reliably
  each cycle — see § next-task rule + `private/notes/2026-06-25-debt-drain-order.md`)
  and keeps raising precision: tests, robustness, error-path fidelity,
  refactors, moderate features, audits. Using `AskUserQuestion` (or any
  "which should I do next / A vs B vs wind-down?" prompt) to choose
  the next task or the next direction is the **Direction-ask smell**
  and is forbidden — the AI decides and proceeds; the user interjects
  if they want a different direction. (`AskUserQuestion` remains fine
  for a genuine in-task fact the AI cannot derive — an external
  credential, a product preference with no sensible default — never
  for "what should I work on next".)

A user "stop" directive applies to **the session in which it was
issued**. It does not carry across to the next session — the next
`/continue` (or any automated re-invocation) resumes the loop
under this rule unchanged. Mechanical backstops re-inject this at
the two points momentum drifts toward an idle turn-end: after
`git commit` (`scripts/post_commit_remind.sh`) and after a test
gate launches (`scripts/gate_continue_remind.sh`) — see those
hooks, not added prose here.

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
> ask the loop to halt. **Cycle / diff / LOC size is not a
> project constraint** — only F-NNN is. If your finished-form-
> clean alternative would expand the cycle's diff substantially,
> recommend it anyway citing F-002; do NOT downgrade your
> recommendation to a smaller-diff alternative on cycle-budget
> grounds (that recommendation pattern is itself the
> Cycle-budget defer smell in `.dev/principle.md`)."

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

**If the DA fork rates Alt N finished-form-clean and the loop's
instinct is a smaller-diff Alt M** citing cycle / LOC budget, that
instinct IS the **Cycle-budget defer smell** (`.dev/principle.md`):
re-pick Alt N. Cycle / diff / LOC is not a project constraint — only
F-NNN is. The sole exception is a real F-NNN block (pick the best
F-NNN-compliant alternative; F-NNN amendment is user-owned).

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
bash test/run_all.sh --smoke <step>  # per-commit smoke (fast; ADR-0107)
bash test/run_all.sh                 # full gate (batched: ceiling/boundary/pre-tag)
zig build -Dwasm -Doptimize=ReleaseSafe  # probe binary (= gate config; -Dcpu=baseline only for deploy)
zig build run          # run executable (`cljw`)
zig fmt src/           # format
```

## Data sources

- [`compat_tiers.yaml`](compat_tiers.yaml) — authoritative Tier A / B /
  C / D classification per var, special form, and host class. Read by
  test runner, REPL error message, and future `cljw --list-vars`. See
  ADR-0013 for the Tier D rationale.
- [`placement.yaml`](placement.yaml) — Clojure-ns var placement SSOT
  (Pattern A/B + transient_zig migration status + dependencies). Read
  by `scripts/check_placement_status.sh` (audit + status flip), future
  `cljw --list-vars` (alongside compat_tiers.yaml), and ADR-0033
  amendment history. Role split: compat_tiers.yaml = Java/cljw surface
  (Class-level), placement.yaml = Clojure-ns vars (var-level). Per
  `private/notes/clj_vs_zig_split_proposal_v5.md` §15.
- [`host_interfaces.yaml`](host_interfaces.yaml) — closed-set SSOT for the
  deftype/reify/extend-type host-supertype markers (`Object`, `clojure.lang.*`).
  Single in-code read point: `src/runtime/host_interface.zig`. Gated by
  `scripts/check_host_interface.sh` (G4: recognised-set ⊆ rows, no over-claim).
  Closes the 個別最適化 entry structurally (ADR-0102, F-013). Distinct from
  compat_tiers.yaml: that = host *class* surface; this = deftype/reify *marker*.
- [`.dev/debt.yaml`](.dev/debt.yaml) — row-level debt ledger. `continue`
  skill Step 0.5 sweeps this on every resume. See ROADMAP §A13.
- [`.dev/reference_clones.md`](.dev/reference_clones.md) — explicit
  usage purpose for `additionalDirectories` paths.
- [`.dev/lessons/INDEX.md`](.dev/lessons/INDEX.md) — observational
  learnings, distinct from load-bearing ADRs.
- [`.dev/gc_rooting.md`](.dev/gc_rooting.md) — SSOT for the GC rooting
  surface: every site that publishes / holds / decodes a GC root (EvalFrame
  producers, root slots, reentrant accumulators, pins, in-txn, per-tag traces,
  the `isGcManaged` membrane) + a moving-GC migration checklist. `GC-ROOT:`
  markers in source anchor each published-root site here.
- [`.dev/zwasm_capabilities.md`](.dev/zwasm_capabilities.md) — cljw's view of the
  **embedded zwasm v2** runtime's embedding-API capabilities + cljw's adoption
  status (F-001). zwasm is SHA-pinned but co-developed (`~/Documents/MyProducts/
  zwasm_from_scratch`) and is growing a **JIT-backed engine** (ADR-0200) — the
  north-star capability (ROADMAP §9.0 gap area II × III). **The loop MUST read this
  ledger at every gap-area-unit start (Step 1a) and every Phase boundary**, refresh
  it against zwasm's live status sources listed there, and flip the JIT row from
  BUILDING→adoptable only when zwasm marks it ready AND the pin is (user-)bumped.
  This is the always-on, git-tracked face of the CODEV co-dev protocol.

## References

- [`.dev/ROADMAP.md`](.dev/ROADMAP.md) — authoritative mission, principles,
  phase plan. **Single source of truth**; if anything in this file
  conflicts with the roadmap, the roadmap wins.
- [`.dev/handover.md`](.dev/handover.md) — short, mutable, current state.
  Framing per [`.claude/rules/handover_framing.md`](.claude/rules/handover_framing.md)
  (≤ 100 lines; driving doc, not session log).
- [`.dev/decisions/`](.dev/decisions/) — ADRs (load-bearing decisions);
  numbers are time-ordered, newest wins on conflict.
