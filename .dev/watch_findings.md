# Watch findings — defer / re-evaluate ledger

> Per Wave 16 design (2026-05-26): every "defer to watch" decision the
> autonomous loop makes during review / planning / Step-0.6 re-laying
> lands a row here. Pre-empts the **Defer-to-amnesia smell** by giving
> each watch a tracked revisit predicate. Audit reads this file every
> `/continue` Step 0.5 sweep + at Phase boundary.

## How an entry is created

When the loop says "defer" / "watch" / "fix later" — in code review,
in a Step 6 self-audit, in a Step 0.6 re-laying, in a survey amend, in
a per-task note design-judgement section — write a row here in the
same edit. Empty defer (= no row) is the smell.

## Row schema

| Field           | Meaning                                                                |
|-----------------|------------------------------------------------------------------------|
| ID              | `W-NNN` (zero-padded 3 digits, time-ordered).                          |
| Source          | Commit SHA + section / file:line where the defer was decided.          |
| Finding         | What the loop saw, in one sentence.                                    |
| Defer rationale | Why deferring is the right call right now (cost / scope / dependency). |
| Revisit trigger | Present-tense, testable predicate. Same shape as debt.yaml Status.     |
| Last reviewed   | Date (YYYY-MM-DD).                                                     |

## Audit consumption

- `/continue` Step 0.5 sweep: walk every row whose `Last reviewed > 14
  days ago` AND re-evaluate the `Revisit trigger`. If true, escalate to
  active work; otherwise refresh `Last reviewed`.
- `audit_scaffolding` E2.8 check at Phase boundary: count + list rows
  whose triggers have fired.
- A row whose finding has been promoted to a real cycle / commit gets
  moved to the `## Discharged` section with the SHA.

## Active

| ID    | Source                                     | Finding                                                                                                                                                                                                                    | Defer rationale                                                                                                                                                                                                                                                                                       | Revisit trigger                                                                                                                                                                                                       | Last reviewed |
|-------|--------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------|
| W-003 | review-fix commit ef4f683 (F11)            | check_provisional_sync.sh file-touched, not content-aware (= any random doc edit to yaml/debt passes when paired with marker change)                                                                                       | Mitigated by audit_scaffolding E2.2 round-trip catching dangling refs. Hook content-awareness is medium-effort.                                                                                                                                                                                       | check_provisional_sync.sh passes a real false-positive in the wild (= someone touches yaml/debt without correspondence).                                                                                              | 2026-05-26    |
| W-004 | review-fix commit ef4f683 (F19)            | scripts/check_provisional_sync.sh diff-rename parse fragile on paths containing literal " b/"                                                                                                                              | No cw v1 paths contain " b/"; truly latent. Refactor to `git diff --name-status -z` would be cleaner but unforced.                                                                                                                                                                                    | A real source path with " b/" lands in cw v1.                                                                                                                                                                         | 2026-05-26    |
| W-005 | review-fix commit ef4f683 (F7-extra)       | CLAUDE.md Step numbering 0 / 0.5 / 0.6 / 1 / 1a — still a fractional cluster. A renumber to 0.a / 0.b / 0.c / 1 / 1.a would stop the fractional drift                                                                     | Wave-15-follow-up flipped 0.7 → 0.6 for monotonicity. The fractional scheme itself is acceptable for now; renumber would churn many citations.                                                                                                                                                       | New step inserted between 0.5 / 0.6 or between 0.6 / 1 (= forces the next fractional 0.55/0.7).                                                                                                                       | 2026-05-26    |
| W-006 | wave16 W16-8 commit fe4bf44                | CLAUDE.md § Autonomous Workflow Step 0..7 spec (~305 lines) overlaps continue/SKILL.md. D-042 authorises moving Step 0..7 detail into continue/SKILL.md, leaving CLAUDE.md with 1-3 line per-step summaries (~ -150 LOC). | Medium risk — CLAUDE.md loads every turn; continue/SKILL.md loads on /continue only. A bad trim could lose mid-session procedural fidelity. W16-8 took the conservative path (-30 LOC via bench policy extraction + Devil's-advocate dedup) instead of the aggressive -150.                          | A real instance where the agent forgets Step N's procedure mid-session AND that procedure was something only continue/SKILL.md carried (= measurable load-bearing gap). Until then the conservative path holds.       | 2026-05-26    |
| W-007 | wave16 self-review (silent-failure-hunter) | check_module_docstring.sh baseline at HEAD 3ebf937 = 28 src/**/*.zig files missing canonical 2-line opener. D-022 row tracks "discipline + backfill" but does not carry a numeric baseline for regression detection.       | The 28 missing files are pre-existing; W16-1 introduced the script as informational and recorded the count in commit body. Numerical baseline can be re-derived by re-running the script; promotion to gate would require partial backfill or per-file exemption tagging.                             | Next Phase 5 entry: re-run `bash scripts/check_module_docstring.sh report`; if count grew vs the 28 baseline a regression landed silently; if shrank a partial backfill landed unannounced — investigate either way. | 2026-05-26    |
| W-008 | wave16 self-review (code-reviewer)         | audit_scaffolding E2.6 stale-Phase scan over-matches: legitimate `until Phase N` doc-strings in `src/lang/primitive.zig`, `uuid.zig`, `macro_dispatch.zig`, `print.zig` are flagged as stale.                              | The 4 legitimate sites are forward-looking narrative, not stale phase refs. Pipe through `grep -v PROVISIONAL:` (mirroring E2.7) would catch most false positives. Effort small; deferred until E2.6 produces a real-cycle false positive (= someone treats a legitimate doc-string as a regression). | E2.6 audit runs and produces a flag against a known-legitimate narrative doc-string + the cycle owner has to manually skip it.                                                                                        | 2026-05-26    |

## Discharged

| ID    | Discharged at | Resolution                                                            |
|-------|---------------|-----------------------------------------------------------------------|
| W-001 | 7ea9aae       | F4 schema doc updated to acknowledge prose-label format.              |
| W-002 | 7ea9aae       | F9 requires_features / requires_debts split landed across 17 entries. |

## Conventions

- Append-only history. A row that gets resolved moves to `## Discharged`
  with the SHA, not deleted.
- Multiple findings from the same review session may share a Source SHA
  — that's fine; the ID is per finding.
- A `Defer rationale` of "no time / will get to it" is the
  Defer-to-amnesia smell — flesh out the real cost or escalate.
- `Revisit trigger` MUST be testable. "When relevant" is not testable.
