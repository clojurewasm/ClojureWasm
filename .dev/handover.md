# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: `129309be` (clean tree, all pushed). Last landing: interop
  `.instance_member` unified dispatch + native String methods (ADR-0050
  am1, Alt 2) — `InteropCallNode.Kind` collapsed to 3 + `field_only`,
  field-first resolver, `op_field_access` retired (op_method_call→0x1A),
  `String.installNativeMethods`. Mac gate 110/110.
- **First commit on resume MUST be**: **Q1 — `(Math/abs -5)` static
  dispatch** (ADR-0050 am1 names it "the immediate follow-on"). Register
  `java.lang.Math` as a `___HOST_EXTENSION` surface
  (`runtime/java/lang/Math.zig`, thin over Zig `std.math` per F-009; add
  to the `java_surfaces` list in `runtime/java/_host_api.zig`) + add
  `java.lang.` short-name resolution to `special_forms.resolveJavaSurface`
  (ADR-0050 R3 follow-up — today only literal + `cljw.` prefix are tried,
  so bare `Math/abs` fails "No namespace: 'Math'"). The `.static_method`
  analyzer/eval arms already exist (TreeWalk) — this is surface + name
  resolution, not new dispatch.
- **Forbidden this session**: re-opening the `.instance_member` work (DONE
  @129309be — kind collapse / field-first / op_field_access retire /
  String native methods all landed). Re-surveying / re-DA'ing the interop
  dispatch shape (LOCKED — ADR-0050 am1). Adopting method-then-field
  ordering (field-first keyed on `field_layout` is the contract). Flipping
  `phase_at_least_14` / tagging v0.1.0 (release HELD). Treating §9.17 `[ ]`
  (14.12 deferred / 14.14 release held) as the next task.

## Current state

Phase 14 v0.1.0 substantive work DONE; release HELD. Mac gate 110/110.
Interop instance-member dispatch unified across both backends; native
String surface (toUpperCase/toLowerCase/trim) reachable as `(.m str)`.
`.static_method` works in TreeWalk; VM arm is VM-DEFER (D-130). F-010-
ordered gaps (JIT / nREPL / line-editor / Wasm-Component / deps) deferred.

## Next milestone (F-010 M = Phase 15 完遂 + cw-v0-level JIT)

§A26 interop coverage: Q1 `Math/abs` (next) + D-130 `.static_method` VM
arm → **Phase 15** (concurrency; unblocks D-117/D-118 nREPL) →
superinstruction/fusion → narrow ARM64 JIT (D-133) → **M** →
quality-elevation loop (`docs/works/`). cw-v0 gap plan in
`.dev/cw_v0_parity_and_gap_plan.md` (§A26).

## Open debts (named; full rows in `.dev/debt.md`)

- **D-130** interop `.static_method` VM arm (rides or follows Q1; bytecode
  shape op_interop_call vs sibling op_static_method_call undecided).
  **D-147** `fn*` self-name slot. **D-076** destructuring. **D-134**
  clojure.core (`partition` 4-arg pad + comp/juxt multi-arity). **D-143**
  apply multi-arity spread. **D-142** Env-scope `*error-context*`.
  **D-141** bench multi-lock. **D-105/D-106** time/net+crypto. **D-116**
  line-editor. **D-117/D-118** nREPL (Phase-15-gated). **D-075** metadata.
  **D-133** JIT floor.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow + § The
only stop) → `.dev/project_facts.md` (esp. F-010) → `.dev/principle.md`
→ `.dev/decisions/0050_unified_interop_call_node.md` (base + § Amendment 1)
→ `src/eval/analyzer/special_forms.zig` (`resolveJavaSurface` ~48 +
`analyzeStaticMethodCall`) + `src/runtime/java/lang/System.zig` (surface
pattern) → ROADMAP §A26 + `.dev/cw_v0_parity_and_gap_plan.md`.
