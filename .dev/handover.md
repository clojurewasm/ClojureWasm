# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Operating mode (user directive 2026-05-27)

完全自律で進める。`[x]` flip / feature_deps status flip / ADR
"Selected:" 確定 / DA subagent の "Recommendation" 採用 等の
framework boundary では **pause + PushNotification しない**。
CLAUDE.md § The only stop の "only user explicit stop halts the
loop" を operative rule として運用し、autonomous-tick framing の
"Reaching for justifications, wait" heuristic は採らない。row /
ADR / cycle 境界はそのまま次の Step 0 survey に roll する。

## Resume contract

- **HEAD**: see `git log` (row 7.9 close is HEAD).
- **First commit on resume MUST be**: §9.9 row 7.10 — Step 0
  survey for D-073 VM backend parity cluster remainder (sub-site d
  `compileRequire` libspec branch + `has_rest` VM mirror re-check +
  diff_test descriptor cleanup). Sub-sites a/b/c/e/f discharged at
  row 7.6 cycle 4. `has_rest` mirror may already be satisfied by
  row 7.9 rest-pack edits (VM shares `tree_walk.callFunction` per
  `vm.zig:573`) — Step 0 must confirm. Reference: ROADMAP §9.9
  row 7.10 + D-073 row in `.dev/debt.md`.
- **Forbidden this session**: (a) `return error.NotImplemented` in
  VM compile arms without `// VM-DEFER:` marker. (b) calling
  `TypeDescriptor.lookupMethod` directly — route via
  `dispatch(rt,env,cs,receiver,protocol,method,args,loc)` or
  `dispatchOrNull(...)`. (c) widening `BytecodeChunk.call_sites`
  beyond ADR-0040 without amendment. (d) manual `defer rt.gc.
  infra.destroy(...)` for ProtocolDescriptor / ProtocolFn /
  TypeDescriptorRef — row 7.7 cycle 1 `rt.trackHeap` owns destroy.
  (e) accessing dropped flat `FnNode.arity/.has_rest/.params/.body`
  — row 7.8 ADR-0041 lifted to `methods` slice + `variadic`.
  (f) re-introducing cw v0 threadlocal `apply_rest_is_seq` —
  row 7.9 ADR-0042 diverges (P4 + F-002); the one-bit-of-intent
  rides in call-frame shape (`args.len == m.arity + 1 ∧
  seq-shaped tag`), not in shared mutable state. (g) widening
  `isRestSeqShaped` tag set beyond `{.list,.cons,.chunked_cons,
  .lazy_seq,.nil}` without ADR-0042 amendment.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow +
§ The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.9 → `.dev/debt.md` Step
0.5 sweep (D-073 sub-site d row + D-090..D-092 follow-ups).

## Current state

Phase 7 IN-PROGRESS — §9.9 rows 7.0..7.9 all [x]. Row 7.10 next.
Branch `cw-from-scratch`. Gate green at HEAD: Mac 50/50 + OrbStack
Ubuntu x86_64 49/49.

## Active task — §9.9 row 7.10

D-073 cluster remainder — VM backend parity. Sub-sites a/b/c/e/f
discharged at row 7.6 cycle 4 (ADR-0040 opcode landing). Remaining:
(d) `compileRequire` libspec branch (needs `op_require_with_libspec`
per DA carve-out from T1); `has_rest` VM mirror re-check (row 7.9
rest-pack lives in `tree_walk.callFunction` which VM shares via
`vm.zig:573`, so this may already be discharged — Step 0 verifies);
diff_test descriptor cleanup (`Runtime.deinit` cleanup of
`rt.gc.infra`-owned protocol descriptors + extended `method_table`
slices so the 2 deferred ADR-0040 `method_call` diff cases land).

## Open questions / blockers

None testable from inside the loop. Outstanding debt by ID: D-073
(this row), D-081 (multimethod ergonomic surface; blocked-by D-012
Phase 15), D-083 (multimethod diff_test parity, opportunistic),
D-085 (keyword-as-fn, opportunistic), D-086 (defrecord `__extmap`,
dedicated cycle), D-087 (deftype Name var binding, opportunistic),
D-088 (protocol fqcn ns-prefix collision, opportunistic), D-089
(row 7.7 Q6 retro-audit cluster — other collection primitives
needing hybrid slow-path, Phase 8+), D-090 (fn-body recur runtime
loop, opportunistic), D-091 (defn docstring + meta-map,
opportunistic), D-092 (map-as-map-key equality, Phase 8+).

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`.
Landmarks: Phase 6→7 boundary triad; row 7.2 (ADR-0008 amend 2);
row 7.3 (ADR-0008 amend 3 + ADR-0038); row 7.5 (ADR-0039); row 7.6
(ADR-0040); row 7.7 (ADR-0008 amend 4 + latent-leak fixes);
row 7.8 (ADR-0041 Option B-extracted); row 7.9 (ADR-0042 Alt 3 —
gated bind-direct rest-pack; cw v0 threadlocal rejected).
