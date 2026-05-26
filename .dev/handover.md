# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (row 7.7 cycle 1 source commit is HEAD).
- **First commit on resume MUST be**: §9.9 row 7.7 cycle 2 — Step 0
  survey for `seq` hybrid (Seqable `-seq` slow-path through
  `dispatch.dispatchOrNull` helper landed cycle 1 in
  `src/runtime/dispatch.zig`; bootstrap defprotocol form in
  `src/lang/clj/clojure/core.clj` extends with `-seq` method). Use
  cycle 1's `count` rewire (`src/lang/primitive/sequence.zig:69-118`)
  as the local-pattern reference; `seq` body at
  `src/lang/primitive/sequence.zig:129-152` is the cycle 2 target.
- **Forbidden this session**: (a) `return error.NotImplemented`
  in VM compile arms without an adjacent `// VM-DEFER:` marker.
  (b) calling `TypeDescriptor.lookupMethod` directly from new
  code — route through `dispatch(rt, env, cs, receiver,
  protocol, method, args, loc)` or `dispatchOrNull(...)`. (c)
  widening `BytecodeChunk.call_sites` semantics beyond ADR-0040
  without an amendment. (d) re-introducing manual `defer rt.gc.
  infra.destroy(...)` for ProtocolDescriptor / ProtocolFn /
  TypeDescriptorRef — `rt.trackHeap` registrations in cycle 1's
  `makeProtocol` / `makeProtocolFn` / `makeTypeDescriptorRef` own
  the destroy via `rt.deinit`.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow
+ § The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.9 → ADR-0008
amendment 4 (R3a-extracted shape + DA fork output) →
`private/notes/phase7-7.7-cycle1.md` (cycle 1 TODO list) →
`.dev/debt.md` Step 0.5 sweep (D-069 row).

## Current state

Phase 7 IN-PROGRESS — §9.9 rows 7.0..7.6 all [x]. Row 7.7 cycle 1
(count hybrid) landed; cycles 2-5 remain. Branch
`cw-from-scratch`. Gate green at HEAD: Mac 48/48 + OrbStack
Ubuntu x86_64 47/47.

## Active task — §9.9 row 7.7 cycle 2

`seq` primitive (`sequence.zig:129-152`) gets the same hybrid
shape cycle 1 landed on `count`: native Tag fast-path arms stay
verbatim; the outer `else =>` routes through
`dispatch.dispatch(rt, env, &cs, coll, SEQABLE_FQCN, "-seq",
args, loc)`. Note `seq` has NO `.typed_instance` arm today
(deftype / defrecord fall into `else =>` and raise), so cycle 2
does NOT face the R3 precedence question — only the outer-else
rewire + bootstrap defprotocol extension for `Seqable -seq`.
Cycle 2 close: 1 new e2e case (defrecord with `-seq` extension)
+ Mac + Linux gates green.

## Open questions / blockers

None testable from inside the loop. Outstanding debt referenced
by ID: D-073 (sub-sites d require_libspec + has_rest VM mirror
+ diff_test descriptor cleanup remain), D-081 (multimethod
ergonomic surface; blocked-by D-012 Phase 15), D-083
(multimethod diff_test parity, opportunistic), D-085
(keyword-as-fn callable, opportunistic), D-086 (defrecord
`__extmap`, dedicated cycle). Cycle 1 surfaced three latent-gap
candidates worth a follow-up debt row at row 7.7 close cycle 5
(per `private/notes/phase7-7.7-cycle1.md` TODO): deftype Name
auto-`(def)` binding, protocol fqcn ns-prefix collision,
`extendTypeWithImpls` old method_table slice leak.

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`.
Landmarks: Phase 6→7 boundary triad (ADR-0036 / ADR-0037 /
ADR-0035 D9 second amendment); row 7.2 close (ADR-0008
amendment 2); row 7.3 close (cycles 1-8.5 + ADR-0008 amendment 3
+ ADR-0038); row 7.5 close (ADR-0039 DA fork); row 7.6 close
(ADR-0040 DA fork); row 7.7 cycle 1 (ADR-0008 amendment 4 R3a-
extracted + DA fork + bundled latent-leak fix).
