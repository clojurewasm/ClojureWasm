# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`.
- **First commit on resume MUST be**: §9.9 row 7.3 cycle 7 first
  red — `expandDefprotocol` / `expandExtendType` /
  `expandExtendProtocol` Zig-side macro transforms in
  `src/lang/macro_transforms.zig`, mirroring row 7.2 cycle 5c
  `expandDefmulti` pattern. Lowering shapes:
  - `(defprotocol P (m [x]))` →
    `(do (def P (rt/__make-protocol! 'P ['m]))
         (def m (rt/__make-protocol-fn! P "m")))`.
  - `(extend-type Foo P (m [x] body))` →
    `(rt/__extend-type! Foo P [["m" (fn* [x] body)]])`.
  - `(extend-protocol P Foo (m [x] ...) Bar (m [y] ...))` →
    `(do (extend-type Foo P (m [x] ...)) (extend-type Bar P
    (m [y] ...)))`.
  New `error_catalog` Codes: `defprotocol_form_incomplete`,
  `extend_type_form_incomplete`, `extend_type_target_invalid`.
  Cycle 8 then lands e2e + diff_test (survey §8 7-case ladder),
  D-082 discharge (typed_instance walk in row 7.2 isaCheck),
  row 7.3 [x] flip.
- **Forbidden this session**: (a) re-deriving Phase 7 entry triad
  (T1 ADR-0036 + T2 ADR-0037 + T3 ADR-0035 D9 second amendment).
  (b) commits adding VM compile arm bodies of the form
  `return error.NotImplemented` without an adjacent `// VM-DEFER:`
  marker. (c) re-introducing evalInNs / op_in_ns auto-refer block.
  (d) calling `TypeDescriptor.lookupMethod` directly from new code
  — route through the row 7.1 `dispatch(rt, env, cs, receiver,
  protocol, method, args, loc)` ABI. (e) Re-deriving row 7.2
  multimethod shape (ADR-0008 amendment 2 Alt 1 binding). (f)
  Re-deriving row 7.3 cycles 1-6.6 — protocol_generation /
  extendTypeWithImpls / CallSite.cached_generation guard /
  ProtocolFn extern / ProtocolDescriptor extern / satisfies helper
  / 4 Layer-2 primitives (`__make-protocol!` /
  `__make-protocol-fn!` / `__extend-type!` / `__satisfies?`) /
  TypeDescriptorRef wrapper / MethodEntry method_val + vt.callFn
  dispatch (ADR-0008 amendment 3) are all landed. (g) Reverting
  MethodEntry to `fn_ptr: ?*const anyopaque` — Alt 2 finished
  form selected per advocate verdict.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` (Bad Smell catalogue) → `.dev/ROADMAP.md` §9.9
→ ADR-0008 (amendment 1 Alt 1 + amendment 2 + amendment 3 all
binding) → `private/notes/phase7-7.3-survey.md` §5 →
`private/notes/phase7-7.3-cycle6.6.md` (latest) →
`feature_deps.yaml` → `.dev/debt.md` Step 0.5 sweep.

## Current state

- **Phase**: Phase 7 IN-PROGRESS — §9.9 rows 7.0 / 7.1 / 7.2 all
  [x]. Row 7.3 cycles 1-6.6 landed: cycle 1 (4f57ee6) → cycle 2
  (b80d853) → cycle 3 (25a9195) → cycle 4 (135e876) → cycle 5
  (5243a50) → cycle 6 (5504499; 3 primitives) → cycle 6.5
  (e634542; TypeDescriptorRef wrapper) → ADR-0008 amendment 3
  (ab03fc3) → cycle 6.6 (143726b; MethodEntry method_val +
  __extend-type!). Active = row 7.3 cycle 7 (macros).
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md`.
- **Gate**: Mac 43/43 + OrbStack Ubuntu x86_64 42/42 green at HEAD
  `143726b`.
- **VM-DEFER markers**: 4 active (3 deftype-family in
  `vm/compiler.zig` + 1 `require_libspec` in `compileRequire`).
  PROVISIONAL markers: D-070 join, D-074 map-invert, D-075 project
  + rename, D-076 rename-keys, D-077 catch_class_table.
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.9 row 7.3 cycle 7

Zig-side macro transforms for `defprotocol` / `extend-type` /
`extend-protocol`. The Layer-2 primitives that the macros lower to
are all landed (cycle 6 + cycle 6.6); cycle 7 is mechanical
lowering per the row 7.2 `expandDefmulti` pattern + the lowering
shapes in the Resume contract above. Detail in
`private/notes/phase7-7.3-cycle6.6.md` "TODO (cycle 7+)" section.

## Open questions / blockers

None testable from inside the loop. D-081 (derive ergonomic
surface) blocked-by D-012 (Atom + swap!, Phase 15 target); neither
blocks row 7.3.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`
for detail. Landmarks: Phase 6→7 boundary triad (T1 ADR-0036 /
T2 ADR-0037 / T3 ADR-0035 D9 second amendment); Row 7.2 close
(5 cycles + ADR-0008 amendment 2); Row 7.3 cycles 1-6.6 incl.
ADR-0008 amendment 3 (MethodEntry method_val + vt.callFn
convergence with row 7.2).
