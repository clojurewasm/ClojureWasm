# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`.
- **First commit on resume MUST be**: §9.9 row 7.3 cycle 6.5 first
  red — `.type_descriptor` Value wrap via NEW `TypeDescriptorRef`
  extern struct (header: HeapHeader + td_ptr: *const TypeDescriptor)
  in `src/runtime/type_descriptor.zig`, plus `makeTypeDescriptorRef`
  factory + `asTypeDescriptorRef` decoder. Then add `__extend-type!`
  primitive to `src/lang/primitive/protocol.zig` (args =
  `.type_descriptor` target + `.protocol` proto + `.vector` impls;
  each impls element is a `[method-name-string fn-val]` pair;
  mutates td via `extendTypeWithImpls`, generation bump landed
  cycle 1). Cycle 6 landed 3 primitives (`__make-protocol!` /
  `__make-protocol-fn!` / `__satisfies?`) at 5504499; rationale in
  `private/notes/phase7-7.3-cycle6.md`. Cycle 7 macros, cycle 8
  e2e+diff. Row 7.3 [x] flip after D-082 discharge.
- **Forbidden this session**: (a) re-deriving Phase 7 entry triad
  (T1 ADR-0036 + T2 ADR-0037 + T3 ADR-0035 D9 second amendment).
  (b) commits adding VM compile arm bodies of the form
  `return error.NotImplemented` without an adjacent `// VM-DEFER:`
  marker. (c) re-introducing evalInNs / op_in_ns auto-refer block.
  (d) calling `TypeDescriptor.lookupMethod` directly from new code
  — route through the row 7.1 `dispatch(rt, env, cs, receiver,
  protocol, method, args, loc)` ABI. (e) Re-deriving row 7.2
  multimethod shape (ADR-0008 amendment 2 Alt 1 binding). (f)
  Re-deriving row 7.3 cycles 1-6 (protocol_generation /
  extendTypeWithImpls / CallSite.cached_generation guard /
  ProtocolFn extern / ProtocolDescriptor extern / satisfies /
  3 Layer-2 primitives all landed). (g) Migrating TypeDescriptor
  itself to extern struct — cycle 6.5 lands a `TypeDescriptorRef`
  wrapper instead (rationale: `phase7-7.3-cycle6.md`).

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` (Bad Smell catalogue) → `.dev/ROADMAP.md` §9.9
→ ADR-0008 (amendment 1 Alt 1 + amendment 2 both binding) →
`private/notes/phase7-7.3-survey.md` §5 →
`private/notes/phase7-7.3-cycle6.md` (latest; cycle 6.5 split) →
`feature_deps.yaml` → `.dev/debt.md` Step 0.5 sweep.

## Current state

- **Phase**: Phase 7 IN-PROGRESS — §9.9 rows 7.0 / 7.1 / 7.2 all
  [x]. Row 7.3 cycles 1-6 landed: cycle 1 (4f57ee6)
  protocol_generation + extendTypeWithImpls; cycle 2 (b80d853)
  CallSite.cached_generation guard; cycle 3 (25a9195) ProtocolFn
  extern; cycle 4 (135e876) ProtocolDescriptor extern; cycle 5
  (5243a50) satisfies helper; cycle 6 (5504499) Layer-2 primitives
  3-of-4. Active = row 7.3 cycle 6.5 (TypeDescriptorRef wrapper +
  `__extend-type!` primitive).
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md`.
- **Gate**: Mac 43/43 + OrbStack Ubuntu x86_64 42/42 green at HEAD
  `5504499`.
- **VM-DEFER markers**: 4 active (3 deftype-family in
  `vm/compiler.zig` + 1 `require_libspec` in `compileRequire`).
  PROVISIONAL markers: D-070 join, D-074 map-invert, D-075 project
  + rename, D-076 rename-keys, D-077 catch_class_table.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.9 row 7.3 cycle 6.5

`.type_descriptor` Value wrap via `TypeDescriptorRef` wrapper +
`__extend-type!` primitive. Step 0.6 re-laying at cycle 6 entry
surfaced that cycles 1-5 shipped runtime helpers without a
Value-wrappable TypeDescriptor shape; cycle 6.5 closes the gap
without churning 11 instantiation sites. Detail in
`private/notes/phase7-7.3-cycle6.md`. After 6.5: cycle 7 macros,
cycle 8 e2e+diff, D-082 discharge, row 7.3 [x] flip.

## Open questions / blockers

None testable from inside the loop. D-081 (derive ergonomic
surface) blocked-by D-012 (Atom + swap!, Phase 15 target);
neither blocks row 7.3.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`
for detail. Landmarks: Phase 6→7 boundary triad (T1 ADR-0036 /
T2 ADR-0037 / T3 ADR-0035 D9 second amendment); Row 7.2 close
(5 cycles + ADR-0008 amendment 2 Alt 1); Row 7.3 runtime-layer
foundation (cycles 1-5) + cycle 6 primitives 3-of-4.
