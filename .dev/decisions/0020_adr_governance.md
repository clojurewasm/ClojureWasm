# 0020 — ADR governance: template extension and "Affected files" discipline

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, adr, governance, template, traceability

## Context

ADR-0001 through 0019 landed without an explicit "Affected files"
field. When amending an ADR (e.g., ADR-0018 amendment 2 cascading
through ADR-0009 / 0010 / 0013 / rules / ROADMAP), the developer
must rediscover the dependency graph each time, and quiet leaks
appear at any forgotten downstream site (the rename `tier_d_form` →
`tier_d_<form>` left 7 sites stale after the first commit and only
the second self-review cycle caught them).

zwasm v1 ADRs and Pollaroid ADR-0044 use an explicit
"Affected files:" section. The pattern is cheap (one section per
ADR) and catches the cascade explicitly at authoring time.

## Decision

Every ADR from 0020 onward carries an **Affected files** section
between Consequences and References. The section lists every file
the decision modifies, with one-line annotations:

```markdown
## Affected files

- `src/path/to/file.zig` — what changes here
- `.dev/ROADMAP.md` §X.Y — what is amended
- `.claude/rules/foo.md` — new / amended
- `scripts/bar.sh` — new
- (etc.)
```

The list is exhaustive at landing time. Amendments append a new
list under `## Revision history` (not edit the original list, so
the historical landing surface stays visible).

`.dev/decisions/0000_template.md` is extended with the new section.
ADR-0001 through 0019 do **not** get the section added retroactively
(the cost outweighs the benefit; the ADRs are already landed and
their cascades are recorded in subsequent commits).

INDEX.md auto-generation (a Pollaroid feature) is **deferred** to
Phase 7+ when the ADR count grows past ~25 and manual indexing
becomes friction. At Phase 4 entry, 20-25 ADRs are scannable by
`ls .dev/decisions/`.

## Alternatives considered

### Alternative A — Retroactive backfill for ADR-0001 through 0019

- **Sketch**: add "Affected files" to all existing ADRs.
- **Why rejected**: the work is large and the cascades are already
  documented in commit messages. The benefit is for *future*
  amendments, not historical ones.

### Alternative B — INDEX.md from day one

- **Sketch**: write a script that scans `.dev/decisions/` and
  generates an INDEX.md.
- **Why rejected**: 19 ADRs are scannable; INDEX.md becomes useful
  at ~25-30 ADRs. Add the script then.

## Consequences

- **Positive**: ADR amendments declare their surface up front.
  Self-review of an amendment commit has a checklist (each file in
  the Affected list must be touched or have a reason not to).
- **Negative**: one extra section to write per ADR. Mitigated by
  the template.
- **Neutral / follow-ups**: INDEX.md auto-gen script lands at
  Phase 7+; track in `debt.md` as a low-priority row.

## Affected files

- `.dev/decisions/0000_template.md` — add Affected files section
- `.dev/handover.md` — update ADR count and reference V5-1 landing
- `.dev/ROADMAP.md` §A19 — Architecture summary doc principle
- `ARCHITECTURE.md` (new) — 5-minute orientation doc

## References

- ADR-0001 through 0019 (the ADRs without "Affected files" that
  motivated this decision)
- Pollaroid ADR-0044 (source-scan enforcement, the structural
  parent of this idea)
- zwasm v1 ADR template (reference for the "Affected files"
  pattern)
- ROADMAP §17 (amendment policy)

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
