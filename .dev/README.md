# .dev/

Project-level design and operational metadata. Tracked in git. English.

## Always present (load-bearing)

- [`ROADMAP.md`](./ROADMAP.md) — **the** authoritative mission, principles,
  architecture, phase plan, success criteria, and quality-gate timeline.
  Single source of truth. If anything elsewhere disagrees with this file,
  this file wins.
- [`handover.md`](./handover.md) — short, mutable, current session state.
  Read at session start, updated at session end. **Framing discipline
  enforced** via [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md)
  (≤ 100 lines, no log accumulation, no forecast tables, no stop-
  rationalisation phrases).
- [`orbstack_setup.md`](./orbstack_setup.md) — one-time VM setup,
  iteration loop, and gate integration for the 🔒 OrbStack x86_64
  cross-platform gate (ROADMAP §11.5).
- [`decisions/`](./decisions/) — Architectural Decision Records.
  - `README.md` — convention.
  - `0000_template.md` — copy this when adding a new ADR.
  - `NNNN_<slug>.md` — accumulated decisions.

## Created on demand (do NOT pre-create as empty stubs)

Empty files rot. Create them when they have real content, using the
templates in **ROADMAP §15.2**:

- `known_issues.md` — long-lived debt log, when the first P0–P3 item appears.
- `compat_tiers.yaml` — per-namespace Clojure tier table, when the first
  `src/lang/clj/<ns>.clj` lands (≈ Phase 10).
- `status/vars.yaml` — per-var implementation tracker, when Phase 2's
  generator script lands (Phase 2.19).
