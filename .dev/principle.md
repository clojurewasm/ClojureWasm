# ClojureWasm v1 — Principles

> The project's working principles in one short file. It does not
> duplicate ROADMAP / ADR / CLAUDE.md. When plan and implementation
> conflict, this file wins; the others should be edited to match.
> Detail lives elsewhere; this file holds only fuzzy premises so it
> does not become a checklist.

## Premises

- **Reason backwards from the finished shape**. Judge today's choice
  by how it will look in the finished form. Ask "how will this part
  read when the project is done?" and pick the choice that fits
  that view.
- **The plan is a means; the finished form is the end**. ROADMAP /
  ADR / rule are tools for reaching the finished form. When the
  tool distorts the finished form, fix the plan side. Ad-hoc
  workarounds that bend the finished form are forbidden.
- **Follow the Bad Smell**. Mid-implementation "wait, this feels
  off" is a signal. Do not suppress it; you have the latitude
  (and the obligation) to interrupt the current activity and
  investigate without compromise. The interrupt is not a stop —
  the loop keeps running, the surgery just lands at the right
  depth before the next step.
- **Latitude and discipline coexist**. Without latitude you can't
  be creative; without discipline you don't reach the finished
  form. Hold both.

## Bad Smell catalogue

Smells that surface during implementation. The list is a memory
aid, not a checklist. Interrupt the current activity on any of
these — and on others that fit the same shape:

- **TODO smell** — wanting to leave a "fix this later" comment in
  the code.
- **Magic constant smell** — "100 for now", "1024 should be fine".
- **Branch sprawl smell** — stacking `if` / `else` three or more
  levels deep.
- **Stub smell** — a do-nothing implementation that lets you feel
  "it works".
- **Spec drift smell** — ROADMAP / ADR text and the implementation
  seem to disagree.
- **Cascade smell** — fixing one file forces touching five others.
- **Resignation smell** — settling for "it can't be helped" or
  "the JVM does it this way too".
- **Premature commitment smell** — the implementation path is
  already settled before the test is written.
- **Test skip smell** — leaning on "I'll write this test in a
  later Phase".
- **Doc drift smell** — implementation changed but ROADMAP /
  handover has not.
- **Shortcut smell** — the proper path looks costly, so a side
  route looks attractive.
- **Workaround smell** — "if I can dodge this point, I can keep
  moving".
- **Smallest-diff bias smell** — picking the smallest-diff option
  *because it is smallest*, rather than because it lands at the
  finished form. The project's premise is "the finished form
  wins"; ROADMAP P5 ("smallest diff first") is a tie-breaker, not
  a veto. If the smallest-diff choice would be re-done later
  anyway, take the bigger surgery now and keep the finished form
  in place.
- **Reservation-as-bias smell** — treating a "reserved" slot /
  number / name as a hard constraint when it was only a memo. ADR
  numbers, NaN-box slots, debt rows that say "future X is
  reserved" — none of these are promises to obey. If the reservation
  blocks the cleanest landing, edit the reservation and take the
  number.
- **Progress-pressure smell** — the autonomous loop's forward
  momentum encouraging "I'll fix this later" / "let me push and
  move on" / "the next task is waiting". Forward momentum is a
  feature, but it must not bypass depth-3 / depth-4 surgery when
  the smell calls for it. "Let me finish 4.X first and come back"
  rarely comes back. Specific surface forms that count as this
  smell triggering: "defer to follow-up cycle", "defer to Phase
  N mid", "open a debt row and pick it up later", "this would
  exceed the LOC budget", "the fusion is the right shape but
  too big for this cycle". When the deferral rationale is
  *cycle-size-based* (not F-NNN-blocked), the smell has fired —
  see also Cycle-budget defer smell.
- **Cycle-budget defer smell** — declining a finished-form-clean
  structural decision **because the current cycle would grow**
  (LOC / file count / migration scope). cw v1 cycles are not
  bounded by an external time budget; the only constraints are
  F-NNN (`project_facts.md`) and the Bad Smell catalogue itself.
  Cycle / diff size is **not** a project constraint and not a
  sufficient reason to file a structural surgery as deferred
  debt. Concrete trigger shape: a Devil's-advocate fork rates
  Alt N as finished-form-clean within the F-NNN envelope, and
  the main loop picks Alt M < N citing "cycle budget" / "this
  expansion is too large now" / "Phase N mid is the right place
  for the rest". That ranking IS the smell. Take the finished-
  form-clean surgery in the same cycle, even when it doubles the
  diff. The exception (= NOT this smell): when the deferral is
  driven by a real F-NNN block (e.g. "the cleaner shape requires
  F-006 to amend; F-006 is user-owned, so we cannot land it
  unilaterally"). In that case the main loop picks the best
  F-NNN-compliant alternative and continues; that is not a
  cycle-budget defer — it is an F-NNN-respecting pick. The
  smell sensor's first question: "is this defer driven by F-NNN
  or by cycle size?" If cycle size, land the surgery.
- **Direction-ask smell** — when the clean / obvious work thins,
  reaching for `AskUserQuestion` (or any "which should I do next /
  A vs B vs wind-down?" prompt) to have the user choose the next
  task or direction. The autonomous loop SELF-SELECTS the next unit
  (finished-form first) and keeps raising precision — coverage while
  it lasts, then quality work (tests, robustness, error-path
  fidelity, refactors, moderate features, audits). "Clean-trivial is
  exhausted" / "the next items differ in character" / "the user has
  been hands-on" are NOT reasons to ask — they are the moment to pick
  the best next unit yourself. (`AskUserQuestion` is still fine for a
  genuine in-task fact you cannot derive — an external credential, a
  product preference with no default — never for "what next".) See
  CLAUDE.md § The only stop.
- **Silent default-shift smell** — a previously established
  default behaviour (decreed in docs OR established by past
  commit pattern) is being silently changed to a different
  default, with no committed text recording the new policy. The
  loop tells itself "it's just my judgement; nobody set this in
  stone" and shifts. Examples: through commit 025dea9 the loop
  staged `bench/quick_baseline.txt` in source-bearing commits;
  from commit 4.6 onward it silently stopped, with no
  conventions / handover / ROADMAP note backing the change (the
  user surfaced this on 2026-05-24 and the policy was made
  explicit in commit bda8b4d as a result). Detection: when you
  notice "what I'm about to do is different from what past
  commits did", **stop and ask**: "is this a policy change?
  Where is it recorded?" If nowhere, either (a) follow the past
  pattern, or (b) record the new policy explicitly (CLAUDE.md /
  principle.md / debt.yaml / a relevant `.claude/rules/*.md` rule)
  before applying the new default. Same shape as Reservation-as-bias
  and Smallest-diff bias — invisible drift away from committed
  intent.
- **Stale-phase-ref smell** — code / docs / scripts cite a Phase
  number ("Phase 4 entry: informational", "until Phase-5 GC
  arrives", "Phase 7+ target") whose status has since shifted in
  ROADMAP §9 (e.g., Phase 4 has closed; Phase 5 GC has landed).
  The cite ages into a lie. Detection: when editing a file, scan
  for `Phase \d+` references and verify against the ROADMAP
  tracker before committing. Example: the 6 placeholder hook
  scripts that said "Phase 4 entry: informational only" while
  Phase 6 was the active phase (surfaced at Wave-16 inventory
  2026-05-26).
- **Framework-incomplete smell** — introducing a new discipline
  (rule / SSOT / hook / marker convention) without, in the same
  cycle, defining the discovery criterion + running the sweep +
  retrofitting existing sites. The result is a 2-tier codebase:
  new sites comply, old sites do not, and nothing tracks the
  asymmetry. See `.claude/rules/framework_completion.md`. Example:
  the Wave-15 spike landed `provisional_marker.md` + yaml + hook
  but missed 5 retrofit sites; silent-failure-hunter caught them
  at review (commit ef4f683 fixed).
- **Defer-to-amnesia smell** — saying "watch" / "defer" / "fix
  later" without recording the deferral in
  `.dev/watch_findings.md` with a testable revisit trigger. The
  decision becomes unrecoverable — no future audit walks the
  deferred set. Example: F4 / F7 / F9 review findings were
  classified "watch" without rows; user prompt later surfaced
  them as the Wave-15-follow-up cycle. The fix is to write the
  `watch_findings.md` row in the same edit as the defer
  decision.
- **Dual-backend drift smell** — landing a new analyzer Node
  variant with a real TreeWalk arm + a VM compile arm that
  silently raises `error.NotImplemented` (or silently drops a
  significant field via `_ = n.some_field;`) without a
  `// VM-DEFER:` marker + tracked debt row. ADR-0005 + F-002
  make dual backend the finished form per ADR-0036; an unmarked
  VM gap is a deferred-amnesia variant specific to the backend-
  parity contract. cw v0's late-Phase catch-up of accumulated VM
  gaps consumed weeks of cycle time; cw v1's
  `scripts/check_dual_backend_parity.sh` PreToolUse hook (per
  ADR-0036 + `.claude/rules/dual_backend_parity.md`) mechanises
  the gate, but the smell sensor remains the first line of
  detection — if you're about to leave a VM arm as
  `error.NotImplemented` without a marker, that is this smell.

The catalogue is not exhaustive. Any felt smell counts.

## When the smell triggers

A trigger is an **interrupt**, not a stop. The loop suspends the
current activity, investigates without compromise, takes the
surgery at the right depth, then resumes. The procedure is fuzzy;
the writer chooses:

1. Suspend the current edit. Re-read the related ADR / ROADMAP /
   surrounding implementation as long as it takes.
2. Fork a subagent if a deeper look is warranted.
3. Imagine how this will look in the finished form.
4. Pick a depth and act on the spot.
5. Land the surgery (commit / ADR / Supersedes chain), then return
   to the per-task TDD flow.

Multiple triggers per cycle just mean multiple interrupts. They do
not accumulate into anything; each is handled and the loop
continues. "Let me finish this task first and come back" is the
Progress-pressure smell — interrupt now, not later.

## Four depths of revision

| Depth          | Situation                                   | Where the conclusion lives                                            |
|----------------|---------------------------------------------|-----------------------------------------------------------------------|
| 1. Local fix   | One file, no ADR cross-reference            | commit message                                                        |
| 2. ADR amend   | Wording of an existing ADR needs adjustment | ADR Revision history                                                  |
| 3. ADR cascade | Several ADRs need amending together         | New ADR amendment + Affected files entries                            |
| 4. Big rewrite | ROADMAP-scale redesign                      | New ADR (`Supersedes NNNN`) + old surface moved to `private/archive/` |

Choosing the depth is the writer's call. The four levels are not a
flow chart.

**All four depths proceed within the autonomous loop.** Depth 2-4
land their conclusion (ADR amendment / new ADR / archive move) in
a separate commit before the source commit, then the loop
continues. The AI drafts and accepts the ADR itself — there is no
external review gate. See CLAUDE.md § Autonomous Workflow
"ADR-level designs are handled inline".

**Devil's-advocate subagent is mandatory at depth ≥ 2.** Before
the ADR is accepted, a `general-purpose` subagent is forked with
**fresh context** to produce 3 alternative shapes (smallest-diff /
finished-form-clean / wildcard) **within the active F-NNN
envelope from `project_facts.md`**. The brief explicitly
instructs the subagent to *not* propose alternatives that
violate any F-NNN; if the only finished-form-clean option would
require violating an F-NNN, the subagent records that finding as
the leading "Alternatives considered" entry — the main loop sees
it, picks the best F-NNN-compliant shape, and continues. The
finding never halts the loop (F-NNN amendment is a user action,
not a loop action). The full output (3 alternatives + any
"violates F-NNN" finding) is embedded verbatim into the ADR's
"Alternatives considered" section. This is the antidote to the
loop's accumulated goal-drift / instruction centrifugation —
alternatives sourced from a context without the main loop's
momentum surface options the main loop is attention-suppressed
against.

## Three questions to picture the finished form

When the sensor interrupts, ask:

1. How will this read when the project is done?
2. Which later Phase actually feels the effect of this choice?
3. If I patch it lightly now, what does the redesign cost look like
   later?

## Structural imagination (before touching structural plans)

> **Origin**: this phase exists because of user invariant **F-003**
> in `.dev/project_facts.md` (decision-deferral over
> decision-seizure on structural plans). The output of past
> imagination cycles lives in `.dev/structure_plan.md`
> (anticipated directory tree Phase 5-20). New imagination
> cycles amend that file in place.
>
> **Scope boundary** (added 2026-05-24 to close a sabotage
> path): Structural imagination applies only to **open
> structural plans** — plans where the direction is not yet
> determined by an `F-NNN` in `project_facts.md`. When an F-NNN
> already fixes the direction, that direction **is the decision**;
> the loop's job is to implement it cleanly, not to re-imagine
> it. Examples at 2026-05-24:
>
> - F-004 fixes NaN-box second generation = 4 × 16 = 64 slot,
>   44-bit pointer. The Phase 5 entry's loop does **not** imagine
>   other layouts; it implements F-004.
> - F-005 fixes the numeric tower shape. The Phase 5 entry's
>   loop does **not** imagine alternative numeric semantics; it
>   implements F-005.
> - F-006 fixes the GC strategy. The Phase 5 entry's loop does
>   **not** consider generational at Phase 5; it implements F-006.
> - F-007 fixes chapter cadence = dormant. The loop does **not**
>   propose resumption on its own.
>
> Where F-NNN leaves room (= directory split timing, file naming
> within the laid-out tree, internal helper organisation, etc.),
> the Structural imagination phase **does** apply, and decisions
> defer to the owning Phase entry's owner as before.

ROADMAP extends through Phase 20. When a task touches a
**structural plan** that future phases will live with, the
autonomous loop is **not** allowed to decide on the structure's
behalf for the future. The decision belongs to the owning
Phase. What the loop **must** do is **imagine the full
ROADMAP range** so the future owner inherits foresight, not a
blank slate.

Structural plans include (at minimum):

- **Reservation tables**: NaN-box slots, enum slots, ROADMAP
  row queue, debt row family.
- **Directory & file structure**: src/ subdirectory layout,
  file-size soft cap (ROADMAP A6 ≤ 1000 lines), candidate splits
  (`value.zig`, `analyzer.zig`, `main.zig` etc.).
- **Responsibility separation**: which file owns which concept,
  whether mixed-concern files need to fan out.
- **Dependency graph**: zone layering (`zone_deps.md`), vtable
  hooks, cross-module references that survive future phases.

What the loop **must** do at any task that touches one of these:

1. Spend a real moment imagining the full ROADMAP range
   (Phase 5–20) and walking through what the structure will need
   to absorb across that horizon. **Do not skip this step**; do
   not shortcut to "let me just decide now".
2. If the imagination reveals a structural gap (table close to
   exhaustion / file headed past the soft cap / responsibility
   leaking / dependency about to cycle / planned ADR will
   collide), record it as a **debt row** scheduled at the owning
   Phase's entry — do not resolve it here.
3. The decision (delete / re-scope / split / keep / extend)
   lands when the owning Phase's task is opened. The current
   loop's job is to set the imagination output up so the future
   owner can resolve cleanly.

This is the antidote to the Progress-pressure smell on
structural work. The smell says "let me clean this up since
I'm here"; the structural imagination phase says "the owner
has the context, I have the foresight — give the owner the
foresight, don't seize the decision".

## How this file is maintained

- Keep it short. Detail belongs in ROADMAP / ADR / rules.
- If another file (ROADMAP / ADR / CLAUDE.md / rule) contradicts
  this one, edit the **other** file. This file is the meta layer.
- Edits to this file ride a normal commit, but they must pass the
  same Bad Smell self-audit that the principle prescribes.
