# 0026 — Phase 5 entry scope decree (cleanup-wave audit outcome)

- **Status**: Accepted
- **Date**: 2026-05-24
- **Author**: Shota Kudo (drafted with Claude, autonomous-loop self-accept per CLAUDE.md § "ADR-level designs are handled inline" after Devil's-advocate subagent review)
- **Tags**: phase-5-entry, cleanup-audit, activation-ordering, D-028

## Context

Phase 4 closed at commit 1f2406a with all §9.6 rows `[x]`. The Phase 5 entry inherits eight Phase-4 skeleton landings (rows 4.13 / 4.17 / 4.18 / 4.19 / 4.20 / 4.22 / 4.23 / 4.24 / 4.25 per debt D-028) that explicitly deferred behaviour to Phase 5. §9.7 task 5.0 (D-028 cleanup-wave audit) ran the survey at `private/notes/phase5-skeleton-audit.md` (676 lines, commit a891c56 task open). This ADR encodes the audit's two load-bearing conclusions — the activation classification table and the critical-path ordering — so §9.7 tasks 5.1-5.16 execute against a fixed surface map without re-deriving the classification.

The audit ran under three constraints: F-002 (finished-form wins over diff size), F-003 (decision-deferral on structural plans), and `no_copy_from_v1` (cw v0 references describe shape, not a port target).

## Decision

### 1. Classification of the eight Phase-4 skeletons

| Row  | File                                | Audit verdict                  | Activation owner                 |
|------|-------------------------------------|--------------------------------|----------------------------------|
| 4.13 | `runtime/io_interface.zig`          | matches FF                     | (deferred Phase 14, ADR-0015 a2) |
| 4.17 | `runtime/type_descriptor.zig`       | needs restructure              | §9.7 row 5.11                   |
| 4.18 | `runtime/protocol.zig`              | needs restructure              | Phase 7 (D-040)                  |
| 4.19 | `runtime/value.zig::ObjectHeader`   | matches FF                     | §9.7 row 5.3                    |
| 4.20 | `runtime/host/_host_api.zig`        | matches FF                     | Phase 6 (host class wave)        |
| 4.22 | `runtime/binding_stack.zig`         | reverted (6a48e90) — terminal | (none)                           |
| 4.23 | `runtime/numeric/big_int.zig`       | needs restructure              | §9.7 rows 5.2 + 5.9             |
| 4.24 | `runtime/lazy_seq.zig`              | needs restructure              | §9.7 row 5.7                    |
| 4.25 | `runtime/dispatch/method_table.zig` | matches FF                     | Phase 7 (D-040)                  |

"matches FF" = the current skeleton shape is what the activation phase will use; activation is body-only work. "needs restructure" = activation touches the struct shape (field add/remove/move), expected and accepted under F-002.

### 2. Critical-path activations for Phase 5 exit

The §9.7 row 5.16 exit smoke (`(get {:a 1} :a)` / `(reduce + (range 1e6))` / `(/ 1 3)` / `(* 9223372036854775807 2)` / `(deftype Point [x y])`) depends on these activations in order: 5.2 (`value.zig` split with F-004 layout), 5.3 (mark-sweep GC), 5.4-5.6 (persistent Vector / HashMap / HashSet), 5.7 (lazy_seq `force()`), 5.8 (List / Cons), 5.9-5.10 (numeric tower), 5.11 (TypeDescriptor), 5.12 (deftype / defrecord / reify), 5.15 (`build_options.phase_at_least_5 = true` flip — mechanical after 5.12, sequential per §9.7.x dependency graph). 5.13 / 5.14 are doc / split clean-ups that ride parallel.

The 🔒 OrbStack gate lock applies per-row: every §9.7 task must pass Mac and Ubuntu x86_64 gates at its own Step 5, not only the exit-smoke row 5.16. The framework finalisation (per ROADMAP §A18) lands when the per-row check_*.sh gates flip from informational to blocking at 5.15.

### 3. Forward-leaning inputs to 5.1 (NOT settled here)

The audit surfaced eight constraints that ADR-0027 (NaN-box 第二世代) + ADR-0028 (mark-sweep GC) co-issue at §9.7 task 5.1 must respect. They live as the survey's "5.1 input bullets" section at `private/notes/phase5-skeleton-audit.md`. 5.1's Step 0/1 reading list already pulls the survey per CLAUDE.md § Step 1a "Phase reading list"; the bullets are quoted into 5.1's ADR Context section at the moment they bind, not pre-committed here.

This split follows the Devil's-advocate Alt 1 recommendation (below): the *verdict table* in §1 commits Phase 5's surface map and needs tracked form; the *constraint bullets* are inputs and live more naturally in the consuming ADR's Context. F-003 (decision-deferral) also covers this: ADR-0026 should not pre-commit decisions the survey only surfaces.

## Alternatives considered

A fresh-context `general-purpose` subagent was forked with the F-001..F-008 envelope as Devil's-advocate per CLAUDE.md § "ADR-level designs are handled inline". The output is reflected here verbatim; the main loop applied Alt 1 (recommendation) with §3 reduced to a pointer instead of removed entirely (the inputs are load-bearing enough to warrant a tracking line; the bullets themselves stay in the survey).

### Subagent summary judgement

The ADR is **substantively correct** but **structurally awkward**: it carries 8 detailed constraint bullets that the §9.7 row 5.1 ADR cluster will *re-quote* (the ADR itself acknowledges this duplication under Consequences/Negative). The audit verdict table is the load-bearing artifact; the 8 bullets are forward-leaning preparation material that arguably belongs in 5.1's "Inputs from 5.0 audit" section, not in ADR-0026. This is the central tension the alternatives explore.

A possibly-more-serious concern: **ADR-0026's "Decision §4 Constraints this ADR does NOT settle" overlaps F-003 (decision-deferral) to the point of restating principle as decision. That section reads like a meta-disclaimer rather than a load-bearing choice.**

### Alt 1 — Smallest-diff: Strip §3 + §4 to a pointer; keep only the verdict table

Sketch: Cut ADR-0026 down to the §1 classification table + the §2 critical-path ordering. Replace §3 (8 constraint bullets) with one line: *"Constraints surfaced by the audit are recorded in `private/notes/phase5-skeleton-audit.md` §'5.1 input bullets' and will be quoted into ADR-0027/0028's Inputs section."* Delete §4 entirely (F-003 already covers deferral as project law; restating it per-bullet adds no commitment).

Better than current draft:

- Removes the duplication Consequences/Negative already concedes.
- Honors ADR-0020's "ONE load-bearing decision" rule more strictly — the load-bearing decision is the verdict table; constraints are inputs.
- Smaller surface to keep synchronized when 5.1 ADRs land.

Breaks / costs:

- Forces 5.1 to depend on a gitignored survey for its 8-bullet Inputs section. This contradicts the Alternative-A rejection rationale in the current draft (which argues the constraints need a tracked record because `private/notes/` is gitignored).
- Loses the "this ADR explicitly says these 8 things bind 5.1" tracking property.
- Resolution: those 8 bullets could be promoted into 5.1's own ADR Context once 5.1 starts — but that timing risk is real (5.1 author might paraphrase, missing constraint #2's `std.atomic.Mutex` subtlety).

### Alt 2 — Finished-form-clean: Split into ADR-0026 (verdict) + a tracked `.dev/phase5_entry_inputs.md` promotion

Sketch: ADR-0026 keeps §1 (verdict table) + §2 (critical-path ordering) + §4 (non-decisions, kept as the F-003 deferral record per row). The 8 constraint bullets in §3 get promoted out of the gitignored survey into a new tracked file `.dev/phase5_entry_inputs.md` (or `.dev/decisions/0026_inputs.md` as an appendix). ADR-0026 §3 becomes a one-line pointer to that tracked file.

Better than current draft:

- Separates two ADR-level concerns cleanly: "what activates where" (ADR-0026) vs "constraints discovered during audit" (tracked inputs doc).
- Tracked inputs doc can be updated independently when 5.1 lands without rewriting ADR-0026.
- Removes the awkward "ADR carries bullets, 5.1 quotes them" double-track.
- F-002 finished-form bias: the cleanest Phase 5 entry record IS a tracked inputs file separate from the verdict ADR.

Breaks / costs:

- Introduces a new tracked-file genre (`.dev/<phase>_entry_inputs.md`) that no other Phase uses. Sets a precedent for Phase 6+ entries that may not generalize.
- Two commits at Phase 5 entry instead of one ADR commit. Mild ROADMAP §17 paperwork increase.
- The "inputs file" pattern blurs with `private/notes/` for surveys that *don't* surface ADR-binding constraints — when is an audit important enough to graduate?

### Alt 3 — Wildcard: Re-frame as ADR-0026 "Phase entry audit pattern" + per-Phase audit appendix

Sketch: ADR-0026 becomes a **pattern decision** (like ADR-0020 governance): "every Phase entry runs a skeleton-audit task and its outputs are promoted from `private/notes/<phase>-skeleton-audit.md` into a §<phase>-audit appendix at the bottom of ROADMAP §9.<N>." Phase 5's specific verdict table + constraints live as **ROADMAP §9.7 appendix** rather than as ADR body. ADR-0026's body teaches the pattern; the Phase 5 instance is the worked example referenced from ROADMAP.

Better than current draft:

- One pattern ADR amortizes across Phase 5 / 6 / 7 / … entries.
- Verdict tables live where activations live (in ROADMAP §9.<N> next to the task rows that cite them), keeping the navigation tight.
- F-002 finished-form: when Phase 12 happens, future agents read ADR-0026-pattern + ROADMAP §9.12 appendix, not "ADR-0026 + ADR-0048 + ADR-0091" (per-phase ADRs).
- Sidesteps the ADR-0020 "ONE decision" tension entirely — the one decision is the *pattern*, not a single phase's verdict.

Breaks / costs:

- Phase 5's specific decisions get less ADR-grade prominence — only listed in ROADMAP, which is mutable per §17 and harder to track historically.
- Pattern ADRs invite premature generalization; Phase 6/7 may not actually need a skeleton audit (depends on how many skeletons land at each Phase 5 entry — and only Phase 4 was the entry that *deliberately* deferred 8 skeletons).
- Bigger structural change at Phase 5 entry; runs against F-002's "diff size is second-tier" only if the pattern actually recurs. If it doesn't recur, this is pure overhead.

### Load-bearing constraints the ADR omits (NEW)

1. **OrbStack gate lock applies to every §9.7 row, not noted in critical path §2.** Each activation task must pass both Mac and Ubuntu x86_64. The exit-smoke row 5.16 carries the 🔒 OrbStack icon in ROADMAP, but 5.1-5.15 each have their own gate too. Not strictly an ADR-level decision, but a finished-form Phase-5-entry record should at minimum cite §A18's framework adoption (per ROADMAP A18, Phase 5 is when `scan_lib.sh` framework finalizes — relevant to 5.x's check_*.sh gate flips at 5.15).
2. **§9.7 row 5.15 build_options flip ordering vs §4 of the ADR.** ADR-0026 §2 lists critical-path activations 5.2 → 5.3 → 5.4-5.6 → 5.7 → 5.8 → 5.9-5.10 → 5.11 → 5.12 but omits 5.15 (build_options flip). Per ROADMAP §9.7.x, 5.15 is sequential-spine ("…→ 5.12 → 5.15 (flip) → 5.16 (smoke)"). The ADR should either list 5.15 in critical path or explicitly say it's omitted because the flip is mechanical-after-5.12.
3. **Constraint #5 + #6 conflate `gc_mark` bit allocation with free-pool link placement.** Bullet 5 says 29 spare bits in `gc_and_lock.gc_mark`; bullet 6 says a `next: ?*HeapHeader` free-pool link is needed somewhere (8 bytes on 64-bit). These are independent decisions — the free-pool link cannot fit in the 29 spare bits (pointer is 64 bits, not 29). The ADR should clarify they are two separate slot-placement questions, not one.

### Redundancy check against existing ADRs

- ADR-0007 / 0008 / 0009 / 0017: ADR-0026 references but does not duplicate; it *cites the activation owner row* for each skeleton these ADRs introduced. No redundancy.
- ADR-0020 (governance): ADR-0026 follows the template (has Affected files). The "Decision §4 Constraints this ADR does NOT settle" section is unusual under ADR-0020 — non-decisions belong implicitly to F-003 / handover queue rather than as a numbered Decision sub-item. Mild structural smell, not a blocker.
- ADR-0025 (chapter dormancy): orthogonal — no overlap.
- No outright duplication with any prior ADR.

### Subagent recommendation (non-binding within F-NNN envelope)

Alt 1 (smallest-diff) as the highest-value change: strip §3 + §4, keep only the verdict table + critical path. The 8 constraint bullets are already faithfully recorded in the survey which the ADR cites. When 5.1 opens, that task's Step 0/1 reading list already includes the survey per CLAUDE.md "Phase reading list"; 5.1's ADR drafts can quote the bullets at the moment they bind.

The current draft's Alternative-A rejection ("private/notes/ is gitignored, need tracked record") is **partially valid but over-applied**: the *verdict table* (§1) genuinely needs tracking because it commits 5.1-5.12 to specific activation owners; the *constraint bullets* (§3) are forward-leaning inputs, not commitments, and live more naturally in the consuming ADR's Context section.

If the main loop prefers tracked constraint bullets, Alt 2 is the cleaner shape. Alt 3 is best long-term if Phase 6+ entries also accumulate skeleton-deferred work, but premature without a second data point.

No F-NNN violation in any alternative.

### Main loop disposition

Alt 1 applied with one carve-out: §3 stays as a one-paragraph pointer (not deleted) so future readers see the link to the survey constraint bullets without having to re-discover them. §4 removed entirely per the subagent's accurate F-003-overlap observation. Omitted-constraints #1 and #2 reflected into §2 (per-row OrbStack lock note + 5.15 in critical-path enumeration). Omitted-constraint #3 (gc_mark / free-pool conflation) is moot now that §3 is a pointer — the conflation lived in the bullets that are no longer in this ADR.

## Consequences

- **Positive**: §9.7 rows 5.1-5.16 execute against a tracked verdict table (which activations belong to which row). Phase 7's D-040 rename plan and Phase 14's ADR-0015 a2 deferral are explicitly preserved. The ADR body shrinks to the load-bearing decision (Alt 1 application).
- **Negative**: 5.1's ADR-0027 / ADR-0028 cluster must pull the 8 constraint bullets from the gitignored survey at the moment they bind. CLAUDE.md § Phase reading list already requires 5.1 to read the survey, so this is mechanically supported, but the risk that 5.1 author paraphrases-and-loses-subtlety (e.g., the `std.atomic.Mutex` Zig-0.16 hazard in bullet #2) is real. Mitigation: 5.1's ADR Inputs section must quote the survey bullets verbatim, not paraphrase.
- **Neutral / follow-ups**: the "needs restructure" verdicts for 4.17 / 4.18 / 4.23 / 4.24 set expectations — under F-002, restructure is information for §9.7 task ordering, not a reason to avoid the work. Alt 3 (pattern ADR for all Phase entries) is recorded for re-consideration at Phase 6 entry: if Phase 6 also accumulates audit-shaped deferred work, the pattern is worth lifting.

## Affected files

- `private/notes/phase5-skeleton-audit.md` (the survey deliverable — gitignored, cited)
- `.dev/ROADMAP.md` §9.7 task table (the activation owners cited above; row 5.0 will flip to `[x]` in the same commit as this ADR)
- `.dev/debt.md` D-028 (this ADR satisfies the audit row; D-028 stays open until the surveyed skeletons all activate)
- Future: `.dev/decisions/0027_*.md` + `.dev/decisions/0028_*.md` (the 5.1 ADR cluster)

## References

- `.dev/project_facts.md` F-002 (finished-form wins), F-003 (decision-deferral), F-004 (NaN-box 64 slot), F-006 (mark-sweep GC + 3-layer allocator)
- `.dev/principle.md` "Structural imagination phase" (the discipline the audit + this ADR jointly satisfy)
- `.dev/decisions/0007_type_descriptor_option_beta.md`, `0008_protocol_dispatch_unify.md`, `0009_object_header_heap_only_lock.md`, `0012_nan_box_valuetag_day1.md`, `0017_allocator_strategy.md`, `0020_adr_governance.md` (the entry ADR set)
- `.dev/debt.md` D-028 (this ADR's row of origin), D-040 (collision deferred to Phase 7)
- `private/notes/phase5-skeleton-audit.md` (the survey)

## Revision history

- 2026-05-24: Status: Proposed → Accepted (autonomous-loop self-accept after Devil's-advocate subagent review reflected verbatim into Alternatives considered above; Alt 1 applied with §3 reduced to a pointer rather than deleted entirely, §4 removed, omitted constraints #1 and #2 reflected into §2).
