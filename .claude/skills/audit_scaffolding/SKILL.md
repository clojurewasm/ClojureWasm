---
name: audit_scaffolding
description: Detect staleness, bloat, dead references, duplicated facts, and false-positive triggers across the project's scaffolding (CLAUDE.md, .dev/, .claude/, docs/, scripts/). Trigger at every Phase boundary, every ~10 ja docs, before a release tag, or when the user explicitly asks for a scaffolding audit. Produces a report; does not modify files.
---

# audit_scaffolding

Audit the *scaffolding* (everything that supports the code, but isn't
the code itself) for the four common rot patterns:

1. **Staleness** — references to files / SHAs / phases / sections that
   no longer exist or no longer match reality.
2. **Bloat** — files past their soft limit, or duplicated facts that
   have started to drift between copies.
3. **Lies** — absolute statements ("we always X", "never Y") that
   reality has overtaken.
4. **False positives** — gate triggers / `.claude/rules/*.md` path
   matchers that fire on commits or files where they shouldn't.

The full check list, grouped by category, lives in
[`CHECKS.md`](./CHECKS.md) next to this file. Read it when running the
audit.

## When to invoke

- **Phase boundary**: every time §9.X completes (last `[ ]` becomes `[x]`).
- **Cadence**: every ~10 ja docs (`docs/ja/00NN`).
- **Pre-release**: before tagging v0.X.0.
- **Explicit**: user says "audit scaffolding" / "check for drift" / similar.

## Procedure

1. Read [`CHECKS.md`](./CHECKS.md). It groups checks by category and
   gives the exact command for each.
2. Run the checks in order. For each finding, classify severity:
   - **block** — must fix before next commit (false positive in gate,
     dead link in CLAUDE.md, broken handover).
   - **soon** — fix this iteration (bloat over soft limit, drifted
     duplication).
   - **watch** — note for later (approaching limit, weak signal).
3. Produce a report at `private/audit-YYYY-MM-DD.md` with three
   sections (block / soon / watch), each finding cited with file:line.
4. Summarise to the user in 5–10 lines:
   - Total findings (block / soon / watch counts)
   - Top 3 most important findings (one line each)
   - Whether to fix now or queue for later
5. Wait for user direction. The audit itself does not modify files;
   the user (or a follow-up commit) does the fixes.

## Output format

```
# Scaffolding audit — YYYY-MM-DD

## block (N)
- <file:line> — <one-line description>
  fix: <one-line suggestion>

## soon (N)
- <file:line> — <description> (fix: ...)

## watch (N)
- <file:line> — <description>

## summary
<2-3 sentence read of overall health>
```

## Why this exists

Scaffolding rot is the failure mode that LLM-driven development is most
prone to: docs and rules accumulate, become contradictory, and the
agent stops trusting any of them. By making the audit a periodic
explicit step (rather than hoping to notice in passing), drift is
caught early and fixed before it confuses the next session.
