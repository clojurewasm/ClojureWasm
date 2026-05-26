# Session handover

> ≤ 100 lines. Driving doc; framing per
> [`.claude/rules/handover_framing.md`](../.claude/rules/handover_framing.md).

## Resume contract

- **HEAD**: see `git log` (row 7.8 cycle 4 close is HEAD).
- **First commit on resume MUST be**: §9.9 row 7.9 — Step 0 survey for
  D-072 `apply` on lazy_seq tail integration via IReduce protocol
  (D-069 amendment). The amendment to row 7.7 cycle 4's `reduce`
  IReduce fast-path: `(apply + (range))` should short-circuit via
  IReduce when lazy_seq carries the protocol entry. Reference: row 7.7
  cycle 4 source (`src/lang/primitive/higher_order.zig::reduceFn`) +
  row 7.9 placeholder in ROADMAP §9.9.
- **Forbidden this session**: (a) `return error.NotImplemented`
  in VM compile arms without an adjacent `// VM-DEFER:` marker.
  (b) calling `TypeDescriptor.lookupMethod` directly from new
  code — route through `dispatch(rt, env, cs, receiver,
  protocol, method, args, loc)` or `dispatchOrNull(...)`. (c)
  widening `BytecodeChunk.call_sites` semantics beyond ADR-0040
  without an amendment. (d) re-introducing manual `defer rt.gc.
  infra.destroy(...)` for ProtocolDescriptor / ProtocolFn /
  TypeDescriptorRef — row 7.7 cycle 1's `rt.trackHeap`
  registrations in `makeProtocol` / `makeProtocolFn` /
  `makeTypeDescriptorRef` own the destroy via `rt.deinit`.
  (e) accessing the dropped flat `FnNode.arity` / `.has_rest` /
  `.params` / `.body` fields — row 7.8 cycle 1's ADR-0041
  Option B-extracted lifted them into a uniform `methods` slice +
  `variadic` slot.

## Cold-start reading order

handover → CLAUDE.md (§ Project spirit + § Autonomous Workflow
+ § The only stop) → `.dev/project_facts.md` (F-001..F-009) →
`.dev/principle.md` → `.dev/ROADMAP.md` §9.9 → `.dev/debt.md`
Step 0.5 sweep (D-072 row + D-090..D-092 row 7.8 follow-ups).

## Current state

Phase 7 IN-PROGRESS — §9.9 rows 7.0..7.8 all [x]. Row 7.9 next.
Branch `cw-from-scratch`. Gate green at HEAD: Mac 49/49 +
OrbStack Ubuntu x86_64 48/48.

## Active task — §9.9 row 7.9

D-072 — `apply` on lazy_seq tail integration via IReduce protocol.
Row 7.7 cycle 4 opened the IReduce extension point on `reduce`;
row 7.9 amends `apply`'s trailing-seq walk to consult IReduce on
the receiver when present, so `(apply + (range))` short-circuits
on the lazy_seq's own IReduce impl instead of full-collecting.
Step 0 survey expected.

## Open questions / blockers

None testable from inside the loop. Outstanding debt referenced
by ID: D-073 (sub-sites d require_libspec + has_rest VM mirror +
diff_test descriptor cleanup remain), D-081 (multimethod
ergonomic surface; blocked-by D-012 Phase 15), D-083
(multimethod diff_test parity, opportunistic), D-085
(keyword-as-fn callable, opportunistic), D-086 (defrecord
`__extmap`, dedicated cycle), D-087 (deftype Name var binding,
opportunistic), D-088 (protocol fqcn ns-prefix collision,
opportunistic), D-089 (row 7.7 Q6 retro-audit cluster — other
collection primitives needing hybrid slow-path, Phase 8+), D-090
(fn-body recur runtime loop, opportunistic), D-091 (defn
docstring + meta-map, opportunistic), D-092 (map-as-map-key
equality, Phase 8+).

## Guardrail refresh history

See `git log -- .claude/rules .dev/decisions .dev/principle.md`.
Landmarks: Phase 6→7 boundary triad (ADR-0036 / ADR-0037 /
ADR-0035 D9 second amendment); row 7.2 close (ADR-0008
amendment 2); row 7.3 close (cycles 1-8.5 + ADR-0008 amendment 3
+ ADR-0038); row 7.5 close (ADR-0039 DA fork); row 7.6 close
(ADR-0040 DA fork); row 7.7 close (ADR-0008 amendment 4 R3a-
extracted + DA fork + bundled latent-leak fixes); row 7.8 close
(ADR-0041 Option B-extracted + DA fork — uniform `FnNode.methods`
slice + per-method recur scopes + `defn` macro multi-arity).
