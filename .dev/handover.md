# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log`.
- **First commit on resume MUST be**: §9.9 row 7.6 first red —
  `(.method instance args)` general-arity protocol method dispatch
  via CallSite cache. ROADMAP row 7.6 description: "5.12.d
  carry-forward — `(.method instance args)` general-arity
  protocol method dispatch via CallSite cache." Rows 7.4
  (defrecord) and 7.5 (reify) closed in the prior session.
  Row 7.6 lights up the `.method` form for arity > 0 (currently
  only arity-2 `.field instance` works at Phase 5.12.a).
  D-073 cluster's 3 deftype-family VM-DEFER sites discharge at
  row 7.6 alongside the bytecode shape decision. Step 0 survey
  required.
- **Forbidden this session**: (a) re-deriving Phase 7 entry triad
  (T1 ADR-0036 + T2 ADR-0037 + T3 ADR-0035 D9 second amendment).
  (b) commits adding VM compile arm bodies of the form
  `return error.NotImplemented` without an adjacent `// VM-DEFER:`
  marker. (c) re-introducing evalInNs / op_in_ns auto-refer block.
  (d) calling `TypeDescriptor.lookupMethod` directly from new code
  — route through the row 7.1 `dispatch(rt, env, cs, receiver,
  protocol, method, args, loc)` ABI. (e) Re-deriving row 7.2
  multimethod shape (ADR-0008 amendment 2 Alt 1 binding). (f)
  Re-deriving row 7.3 — all 12 cycles + 4 ADR amendments landed
  (cycles 1-8.5). (g) Reverting MethodEntry to `fn_ptr: ?*const
  anyopaque` (Alt 2 finished form). (h) Reverting analyzeDef to
  lazy-intern (ADR-0038 selected Alt 2 over status quo).

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` (Bad Smell catalogue) → `.dev/ROADMAP.md` §9.9
→ ADR-0008 (all 3 amendments binding) + ADR-0038 (analyzeDef
pre-register) → `private/notes/phase7-7.3-cycle8*.md` for row 7.3
end-state → `feature_deps.yaml` → `.dev/debt.md` Step 0.5 sweep.

## Current state

- **Phase**: Phase 7 IN-PROGRESS — §9.9 rows 7.0 / 7.1 / 7.2 / 7.3
  / 7.4 / 7.5 all [x]. Row 7.4 (defrecord) closed across 6 cycles
  (commit chain 202c794 → cycle 6). Row 7.5 (reify) closed across
  4 cycles (10b06cc + d87e72b + 975cd3a + this commit): macro
  skeleton → ADR-0039 ReifiedInstance minimal layout + dispatch
  arm + GC hooks → `__reify!` happy path → D-082 discharge
  (isaCheck typed_instance/reified_instance descriptor walk).
  ADR-0039 + Devil's-advocate fork landed.
  D-082 DISCHARGED. D-085 (keyword-as-fn) and D-086 (defrecord
  `__extmap`) remain opportunistic. Active = row 7.6
  (`.method instance args` dispatch + D-073 cluster discharge).
- **Branch**: `cw-from-scratch`. v5 plan =
  `private/notes/clj_vs_zig_split_proposal_v5.md`.
- **Gate**: Mac 44/44 + OrbStack Ubuntu x86_64 44/44 green at HEAD
  row 7.4 close commit.
- **VM-DEFER markers**: 4 active (3 deftype-family in
  `vm/compiler.zig` + 1 `require_libspec` in `compileRequire`).
  PROVISIONAL markers: D-070 join, D-074 map-invert, D-075 project
  + rename, D-076 rename-keys, D-077 catch_class_table, D-086
  defrecord __extmap (2 markers in assocFn).
- **Chapter cadence**: dormant per ADR-0025 + F-007.

## Active task — §9.9 row 7.6 (`.method` dispatch + D-073 cluster)

`(.method instance args)` general-arity protocol method dispatch
via CallSite cache. Phase 5.12.a only ships arity-2 `.field instance`
as a struct field read; row 7.6 extends to multi-arg form via the
row 7.3 dispatch ABI. D-073 cluster's 3 deftype-family VM-DEFER
sites (deftype_node / ctor_call_node / field_access_node in
vm/compiler.zig) discharge at this row alongside the bytecode shape
decision (op_method_call or extend op_call with method-resolution
operand). ADR-0036 dual_backend_parity contract applies.

## Open questions / blockers

None testable from inside the loop. D-081 (multimethod ergonomic
surface) blocked-by D-012 (Atom + swap!, Phase 15 target).
D-083 (multimethod diff_test parity) opportunistic. D-085
(keyword-as-fn callable) opportunistic — needs Layer-0 lookup
helper. D-086 (defrecord __extmap overflow) dedicated cycle later.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`
for detail. Landmarks: Phase 6→7 boundary triad (ADR-0036 /
ADR-0037 / ADR-0035 D9 second amendment); Row 7.2 close (5 cycles
+ ADR-0008 amendment 2); Row 7.3 close (cycles 1-8.5 + ADR-0008
amendment 3 + ADR-0038; per-Tag descriptor registry + analyzer
pre-register + .protocol_fn dispatch arm).
