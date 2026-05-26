# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (last push `9493a98`).
- **First commit on resume MUST be**: §9.9 row 7.7 Step 0 survey
  — D-069 polymorphic primitives (count / seq / conj / reduce)
  refactored to hybrid Zig Tag-switch fast-path + Protocol
  extension point (`extend-type` reaches native tags). Survey
  brief: Clojure JVM `clojure.core/count/seq/conj/reduce` +
  cw v1 current shapes (`src/lang/primitive/sequence.zig`,
  `src/lang/primitive/collection.zig`) + hybrid wiring through
  the row 7.3 per-Tag descriptor registry.
- **Forbidden this session**: (a) `return error.NotImplemented`
  in VM compile arms without an adjacent `// VM-DEFER:` marker.
  (b) calling `TypeDescriptor.lookupMethod` directly from new
  code — route through the row 7.1 `dispatch(rt, env, cs,
  receiver, protocol, method, args, loc)` ABI. (c) widening
  `BytecodeChunk.call_sites` semantics beyond ADR-0040 without
  an amendment.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow
+ § The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.9 → entry ADRs for
row 7.7 (TBD by Step 0 survey) → `.dev/debt.md` Step 0.5 sweep
(D-069 row).

## Current state

Phase 7 IN-PROGRESS — §9.9 rows 7.0..7.6 all [x]. Active = row
7.7. Branch `cw-from-scratch`. Gate green at HEAD: Mac 47/47 +
OrbStack Ubuntu x86_64 46/46.

## Active task — §9.9 row 7.7

D-069 — refactor `count` / `seq` / `conj` / `reduce` primitives
to hybrid shape: Zig Tag-switch fast-path for native tags +
Protocol extension point that `extend-type` reaches. Today the
primitives raise `type_arg_invalid` on unknown tags; row 7.7
opens them via the row 7.3 dispatch ABI so user-defined
defrecord/reify can extend them. Step 0 survey required.

## Open questions / blockers

None testable from inside the loop. Outstanding debt referenced
by ID: D-073 (sub-sites d require_libspec + has_rest VM mirror
+ diff_test descriptor cleanup remain), D-081 (multimethod
ergonomic surface; blocked-by D-012 Phase 15), D-083
(multimethod diff_test parity, opportunistic), D-085
(keyword-as-fn callable, opportunistic), D-086 (defrecord
`__extmap`, dedicated cycle).

## Stopped — user requested

User instruction (2026-05-26): 「きりが良く次の準備ができた
ところで止めてね」. Session closed rows 7.4 / 7.5 / 7.6.
Resume at §9.9 row 7.7.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`.
Landmarks: Phase 6→7 boundary triad (ADR-0036 / ADR-0037 /
ADR-0035 D9 second amendment); row 7.2 close (ADR-0008
amendment 2); row 7.3 close (cycles 1-8.5 + ADR-0008 amendment 3
+ ADR-0038); row 7.5 close (ADR-0039 DA fork); row 7.6 close
(ADR-0040 DA fork).
