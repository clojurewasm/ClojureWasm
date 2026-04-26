# .dev/

Project-level design and operational metadata. Tracked in git. English.

## Files

- [`ROADMAP.md`](./ROADMAP.md) — **the** authoritative mission, principles,
  architecture, phase plan, and success criteria. Single source of truth.
  If anything elsewhere disagrees with this file, this file wins.

## Conventions for additions

Future files should each have a clear, narrow responsibility:

- `decisions/` — Architectural Decision Records (ADRs), one per file.
  Files added here trigger the commit-snapshot doc gate
  (see `.claude/skills/code-learning-doc/SKILL.md`).
- `status/` — Tracker YAMLs (e.g., per-namespace implementation status).
- `handover.md` — Short-lived session-to-session notes.
- `known_issues.md` — Long-lived bugs, workarounds, debt.
- `compat_tiers.yaml` — Per-namespace Clojure compatibility tier (A/B/C/D).

Add only when needed; do not pre-create empty placeholders.
