# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).
> Updated at session end; reads in < 30 sec at cold start.

## Next 3 files to read (cold-start order)

1. `.dev/handover.md` (this file)
2. `CLAUDE.md` § Project spirit — newly added at top, governs all
   other rules; especially the **Reservation-as-bias** and
   **Smallest-diff bias** smells in `.dev/principle.md`.
3. `.dev/ROADMAP.md` — find IN-PROGRESS phase in §9, take the
   first `[ ]` row in §9.<N>. (Note 2026-05-23 cleanup-wave smell
   banner above the §9.6 row table — debt D-028 audit pending.)

## Current state

- **Phase**: Phase 4 IN-PROGRESS. §9.6 critical-path closed
  (4.0 / 4.0a / 4.1 / 4.2 / 4.3 / 4.4 / 4.5 / 4.6 / 4.7 / 4.8 /
  4.9 / 4.10 / 4.11 / 4.12 done). Cleanup wave: 4.13–4.24 done
  (status table refreshed 2026-05-23). Remaining §9.6 rows
  (4.25 / 4.26.a-f) — method_table skeleton + error-system
  migration.
- **Branch**: `cw-from-scratch` (long-lived; push free after gate
  green; never push to `main`).
- **Gate**: Mac 12/12 + OrbStack Ubuntu x86_64 11/11 green at
  HEAD. 🔒 fresh OrbStack run due at Phase 4 close.
- **Chapter cadence**: dormant per ADR-0025; existing chapters
  under `docs/ja/archive/`. `private/notes/<task>.md` continues.
- **Unpaired source SHAs**: irrelevant during dormancy. Resumption
  ADR re-engages chapter cadence.

## Guardrail refresh (post-2026-05-23 session)

User-directed correction. The autonomous loop accumulated multiple
smells during the cleanup wave; the guardrails were strengthened
so the next session does not re-produce them:

- **Project spirit** — added to CLAUDE.md top: finished-form
  cleanliness wins, shipping fast and avoiding rework are
  second-tier. Surgical big edits welcome when the plan misses
  something.
- **Bad Smell catalogue** — 3 new entries in `principle.md`:
  **Smallest-diff bias**, **Reservation-as-bias**,
  **Progress-pressure**. ROADMAP P5 ("smallest diff first")
  re-framed as a tie-breaker, not a veto.
- **D-021 retired** — ADR number reservation is a smell; numbers
  are time-ordered (`max + 1` at issue).
- **D-027 added** — NaN-box layout 第二世代 ADR is owed at Phase
  5 entry (current `big_int` / `ratio` at Group D is a
  smallest-diff landing, not the finished form).
- **D-028 added** — ROADMAP §9.6 cleanup-wave rows (4.13 / 4.16 /
  4.17 / 4.18 / 4.20 / 4.22) need audit + amendment before Phase
  5 entry; the row table now carries a smell banner.
- **ADR-0029 → ADR-0025** rename — chapter archive boundary
  re-numbered to time-ordered slot.

## Active task — §9.6 / 4.25

`src/runtime/dispatch/method_table.zig` — `MethodEntry` struct
(interned symbol + fn ptr) and `CallSite` struct (`last_type` +
`last_method` cache slots) declaration. **But first re-read D-028**
— 4.25 is itself a skeleton-row candidate; consider whether the
smallest-diff landing or "Phase 7 entry: struct + dispatch
together" is the cleaner shape before writing the file.

**Retrievable identifiers**:

- ROADMAP §9.6 task 4.25, ADR-0008 (protocol dispatch unify),
  debt D-028 (cleanup-wave audit).
- The new file lives in a `src/runtime/dispatch/` subdirectory
  which does not yet exist — create it.

## Open questions / blockers

None testable from inside the loop. Recall triggers + follow-up
candidates live in [`debt.md`](./debt.md) (rows `D-005` through
`D-028`). Step 0.5 debt sweep walks them at resume; pay attention
to **D-027 / D-028** which encode the design surgery this
session's guardrail refresh anticipates.
