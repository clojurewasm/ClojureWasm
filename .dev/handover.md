# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`.
- **First commit on resume MUST be**: §9.9 row 7.3 cycle 1 first
  red — `test "extendType bumps protocol_generation and adds
  method_table entry"` in `src/runtime/protocol.zig`. Forces:
  (a) `Runtime.protocol_generation: u32` field, (b) `extendTypeWithImpls`
  helper that re-allocates `TypeDescriptor.method_table` with new
  entries appended (re-alloc + swap per survey §5.2), and (c)
  the generation bump on extension. Step 0 survey is COMPLETE at
  `private/notes/phase7-7.3-survey.md` (647 lines; mirrors row
  7.2's Alt 1 pattern — macros over primitives, no analyzer
  Nodes, no VM-DEFER markers).
- **Forbidden this session**: (a) re-deriving Phase 7 entry triad
  (T1 ADR-0036 + T2 ADR-0037 + T3 ADR-0035 D9 second amendment).
  (b) commits adding VM compile arm bodies of the form
  `return error.NotImplemented` without an adjacent `// VM-DEFER:`
  marker. (c) re-introducing evalInNs / op_in_ns auto-refer
  block (T3 removed it per ADR-0035 D9 second amendment).
  (d) calling `TypeDescriptor.lookupMethod` directly from new code
  — route through the 7.1 `dispatch(rt, cs, receiver, protocol,
  method, args)` ABI. (e) Re-deriving row 7.2 multimethod shape —
  ADR-0008 Phase 7.2 amendment (Alt 1) is the binding decision
  (no analyzer Nodes, no VM-DEFER markers; macros over primitives).

## Cold-start reading order

handover (this file) → CLAUDE.md (§ Project spirit + § Autonomous
Workflow + § The only stop) → `.dev/project_facts.md` (F-001..F-009)
→ `.dev/principle.md` (Bad Smell catalogue incl. "Dual-backend
drift") → `.dev/ROADMAP.md` §9.9 → ADR-0008 (entry ADR; cycle 5c
amendment 2 is the row 7.2 contract) → `feature_deps.yaml` →
`.dev/debt.md` (Step 0.5 sweep; new D-081 / D-082 / D-083 carve-outs).
Phase 7 entry triad history (archival):
`.dev/archive/phase7_entry_prereq_triad.md` + ADRs 0035 / 0036 /
0037. Row 7.2 closure notes:
`private/notes/phase7-7.2-cycle{1,2,3,4,5}.md`.

## Current state

- **Phase**: Phase 7 IN-PROGRESS — §9.9 rows 7.0 [x] / 7.1 [x] /
  **7.2 [x]** (`4d78871`; defmulti / defmethod / prefer-method
  ladder green; derive ergonomic + typed_instance walk +
  diff_test parity carved out via D-081 / D-082 / D-083). Active
  = row 7.3 defprotocol satisfy + extend-type / extend-protocol.
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md`.
- **Gate**: Mac 42/42 + OrbStack Ubuntu x86_64 42/42 green at
  HEAD `4d78871`.
- **VM-DEFER markers**: 4 active sites (3 deftype-family in
  `vm/compiler.zig` + 1 `require_libspec` in `compileRequire`).
  PROVISIONAL markers: D-070 join, D-074 map-invert, D-075 project
  + rename, D-076 rename-keys, D-077 catch_class_table.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.9 row 7.3

Row 7.3 = D-014d: `defprotocol` satisfy + `extend-type` /
`extend-protocol` + CallSite cache full activation. Entry ADR:
ADR-0008 (the protocol-dispatch unify ADR). Builds on row 7.1
dispatch ABI (CallSite cache) + row 7.2 multimethod surface.

The `extend-type` activation makes user-defined typed_instance
receivers reachable from the dispatch path. D-082 (typed_instance
isaCheck DIVERGENCE) discharges as part of row 7.3 work because
typed_instance receivers become user-constructible then.

CallSite generation invalidation (ADR-0008 amendment 1, deferred
per Devil's-advocate Alt 1 from row 7.1): may also land in row 7.3
when `extend-type` introduces the invalidation consumer
(`extend-type` mutates protocol impls, invalidating prior CallSite
caches).

## Open questions / blockers

None testable from inside the loop. D-081 (derive ergonomic
surface) blocked-by D-012 (Atom + swap!, Phase 15 target) or a
follow-up `alter-var-root` primitive — neither blocks row 7.3.

## Guardrail refresh history (condensed)

Waves 1-16 (2026-05-23..26): F-NNN + Bad Smell + ADR-0029..0035 +
provisional-marker mechanisation + handover_framing hook. Phase 6
close + Phase 7 open: ADR-0035 + §9.9 16-row table. Phase 7
entry prereq triad (2026-05-26): T1 ADR-0036 dual-backend parity +
T2 ADR-0037 Symbol heap Value + T3 ADR-0035 D9 second amendment.
Phase 6→7 boundary review chain (audit-2026-05-26) clean —
4 stale-phase-ref drift cleaned inline. Row 7.2 close (this
session, 2026-05-26, 5 cycles + ADR-0008 amendment 2): cycle 1
MultiFn struct + getMethod, cycle 2 isaCheck + hierarchy walk,
cycle 3 prefer-method + dominates, cycle 4 method_cache + cache
invalidation, cycle 5 callMultiFn + Layer-2 primitives + macros +
ladder e2e. ADR-0008 amendment 2 (Alt 1, macros-over-primitives)
selected per Devil's-advocate fork. 3 new debt rows D-081 /
D-082 / D-083 carve out the deferred surface (derive ergonomic /
typed_instance walk / diff_test parity).
