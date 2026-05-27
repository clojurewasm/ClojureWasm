# 0045 — Phase 9 scope reconciliation: external Clojure modules (not "protocols + multimethods + deep interop")

- **Status**: Accepted
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: roadmap, amendment, F-002, Phase-9, Phase-10

## Context

ROADMAP §9 master table row 9 originally read:

> | 9     | Protocols + Multimethods + Interop deep module |
> | defprotocol / defmulti work; single Interop module complete |

This wording dates to the pre-Phase 7 ROADMAP draft, when the
Phase order placed the protocol + multimethod + host interop
work at Phase 9. The subsequent ADR cluster (ADR-0008 protocol
dispatch / ADR-0029 java + cljw surface layout) pulled that
scope **forward** into Phases 6 + 7:

- Phase 6 (§9.8, closed 2026-05-26) landed `host_classes` first
  wave: `java.util.UUID` / `java.io.File` / `java.time.Instant`
  / `java.util.Random` / `java.lang.System` (= row 6.10+ of
  §9.8) via ADR-0029's surface convention.
- Phase 7 (§9.9, closed 2026-05-27) landed defprotocol /
  defmulti / deftype / defrecord / reify / `(.method obj args)`
  protocol method dispatch (= rows 7.1-7.7 of §9.9).

By the time Phase 9 (§9.11) opened on 2026-05-27, the original
Phase 9 mission was effectively discharged across Phases 6-7.
The Phase 9 entry owner (this autonomous-loop session) faced
the choice:

1. Wait for protocol / multimethod / host interop work to
   re-emerge → no scope candidates surfaced; the work was done.
2. Reuse the slot for the next-natural Tier-A surface that the
   master table did NOT enumerate but the per-phase placeholder
   notes flagged → "external Clojure modules" (json / csv / edn
   / tools.cli) per `.dev/structure_plan.md:108-112` + D-034.

The Phase 9 entry note (§9.11 placeholder, pre-amendment) said:

> "the Deliverables line below currently reads 'protocol / host
> complete behaviours' which overlaps the Phase 7 (§9.9)
> protocol dispatch + Phase 6 (§9.8) host stdlib first-wave
> content. Reconcile the Phase 9 scope to match its actual
> focus (external Clojure modules — json / csv / edn) before
> opening the task table; the current text is a historical
> artefact from the pre-amendment ROADMAP."

The Phase 9 entry owner picked option (2). Phase 9 landed:

- row 9.1 — `modules/` top-level + zone rule (D-034 discharged)
- row 9.2 — `clojure.edn/read-string` + formToValue lift
- row 9.3 — `clojure.data.json/{read-str,write-str}`
- row 9.4 — `clojure.data.csv/{read-csv,write-csv}` RFC 4180
- row 9.5 — `clojure.tools.cli/parse-opts` minimum
- row 9.6 — exit smoke + D-007 self-host viability discharged

This ADR formalises the §9 master-table edit that the actually-
landed Phase 9 demands.

## Decision

Amend `.dev/ROADMAP.md` §9 master table row 9 in place per
§17.2 four-step amendment. New wording:

> | 9     | Modules layer + external standard libraries (clojure.edn / .data.json / .data.csv / .tools.cli) |
> | All 4 external Tier-A namespaces ship; `modules/` top-level dependency rule enforced; self-host viability re-verified |

The original protocol / multimethod / interop scope is **not
lost** — it landed across Phases 6 + 7 ahead of schedule. §9
master table rows 6 + 7 already describe their realised content
correctly; only row 9 was mismatched.

## Why now (Phase 10 row 10.1)

The Phase 9 → 10 boundary audit flagged this as a medium
finding (not block-severity because the actually-landed Phase 9
content is captured correctly in §9.11). Row 10.1 of §9.12
schedules the §17 amendment as Phase 10's first task so the
master-table row stops contradicting the per-phase expansion.

Per §17.1: this qualifies as "an exit form / scope row /
task description references a feature whose implementation is
scoped to a different phase" — exactly the canonical case for
the in-place amend.

## Alternatives considered

**Alt 1 — Leave row 9 as-is**, document the divergence in
handover only. Rejected: violates §17.3 "Editing ROADMAP
without an accompanying ADR for load-bearing changes (anything
in §1, §2, §4, §5, §9 phase rows...)". The §9 row IS a
load-bearing surface that downstream readers (= future cw v1
maintainers, audit_scaffolding sweep) trust as the canonical
phase mission statement.

**Alt 2 — Add a "Revision history" annotation to row 9**.
Rejected: §17.2 forbids inline change-bars / dated comments /
strikethrough. The §17 doctrine is "write as if it had always
been so"; the ADR is the changelog.

**Alt 3 — Rename Phase 9 to a different number**. Forbidden by
§17.3 "Quiet renumbering of §N headings". Phase 9 stays
Phase 9; only its mission row text changes.

## Consequences

**Positive**:
- §9 master table becomes truthful at the granular row level.
- `audit_scaffolding` Phase-boundary sweeps no longer flag the
  row 9 mismatch.
- Phase 10 entry owner can reference §9 row 9 directly when
  discussing what's actually built.

**Negative**:
- A non-load-bearing concern: external readers comparing this
  ROADMAP to earlier git revisions (or to mirrors elsewhere)
  see the row 9 wording change. The ADR's "Context" section
  preserves the original wording for that audit trail.

## Affected files

- `.dev/ROADMAP.md` §9 master-table row 9 (this commit's diff)
- This ADR file (`0045_phase9_scope_modules_externals.md`)
- `git log -- .dev/ROADMAP.md` will show the amendment
  referencing ADR-0045

## References

- §17 Amendment policy (the procedure this ADR satisfies)
- §9.11 Phase 9 task list (the actually-landed content)
- §9.12 Phase 10 row 10.1 (the task that drives this ADR)
- ADR-0029 (Java + cljw surface layout — the carrier ADR for
  the host interop work that landed across Phases 6 + 7)
- ADR-0008 (Protocol dispatch — the carrier ADR for protocol /
  multimethod work that landed across Phase 7)
- Original Phase 9 mission text (preserved in this ADR's
  "Context" section)
