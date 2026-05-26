# 0008 — Unify `.method` and protocol dispatch through TypeDescriptor

- **Status**: Accepted
- **Date**: 2026-05-23
- **Author**: Shota Kudo (drafted with Claude)
- **Tags**: phase-4-entry, dispatch, protocol, dot, host-interop

## Context

The corpus carries 5,901 distinct `.method` patterns (top 15 alone:
`.get` 1,126; `.write` 1,094; `.getName` 791 …). Constructor shorthand
`(ClassName. ...)` and `(new ClassName ...)` add several thousand more
occurrences. Threading macros (`->`, `->>`, `..`, `doto`) compound the
total.

On the JVM these reach `VarHandle`, `MethodHandle`, and ultimately
`invokevirtual` with C2's polymorphic inline cache. cw v1 has no JVM
and no JIT (Phase 17 go / no-go), so the dispatch strategy must be
designed up front.

## Decision

Every `.method` call dispatches through the same path: locate the
`MethodEntry` on the receiver's `TypeDescriptor.method_table` (a
slice sorted by interned method-symbol pointer) and invoke its
function pointer.

`(.method obj arg)` is analyzed into a call that:

1. Resolves the method symbol once at compile time.
2. Looks up `obj.typeDescriptor().lookupMethod(method)`.
3. From Phase 7 onward, a per-call-site `CallSite` cache stores the
   last `(TypeDescriptor*, method_fn)` pair for a monomorphic fast
   path.

`(ClassName. args)` is rewritten by the reader to `(new ClassName args)`.
`new` is a special form whose analyzer resolves `ClassName` to a
`TypeDescriptor` and invokes its constructor.

Host-imported types (UUID, Date, File, …) get the same machinery: a
host module under `src/runtime/host/` registers a `TypeDescriptor`
whose `method_table` points at native Zig functions. From the user's
perspective the dispatch is identical.

`import`, `doto`, and `..` are pure macros in `clojure.core.clj` and
need no special-form support beyond what `new` and `dot` already
provide.

## Alternatives considered

### Alternative A — Reflective dispatch (JVM style)

- **Sketch**: at runtime, look up method by name through a global
  registry.
- **Why rejected**: this is the path that produced JVM's
  `Reflector.java` and the corresponding performance pain. cw v1
  has no JIT to dig out from under it.

### Alternative B — Direct vtable indexing per method

- **Sketch**: assign each method-name a global integer slot; types
  store a sparse vtable indexed by slot.
- **Why rejected**: works for closed worlds, not for Clojure's
  open-world dispatch (protocols extend after the fact).

## Consequences

- **Positive**: a single dispatch path covers cw-native and
  host-imported types. `MethodEntry` is small (interned symbol + fn
  pointer). `CallSite` cache yields monomorphic dispatch hot loops.
- **Negative**: megamorphic dispatch (10+ types at one site) reverts
  to binary search through `method_table`. Acceptable for cw v1's
  target workloads; revisit at Phase 8+ if benchmarks flag a
  hotspot.
- **Neutral / follow-ups**: ADR-0007 carries the `TypeDescriptor`
  shape; ADR-0011 covers how `host` module entries register.

## Phase 7+ migration note (amendment 1)

The Phase 4 skeletons (task 4.18 `protocol.zig`, task 4.25
`method_table.zig`) declare `ProtocolDescriptor` / `MethodEntry` /
`CallSite` structs without dispatch logic. Phase 7 entry
activation includes a rewrite:

- `dispatch(callsite, receiver, method, args)` implementation with
  cache-fill on miss (`last_type` + `last_method` slot in
  `CallSite`).
- The Phase 5 path that activated `TypeDescriptor.lookupMethod`
  (see ADR-0007 amendment 1) is rewired through `dispatch` so that
  `.method` / `(.method obj args)` / `new` / `import` / `doto` /
  `..` go through `method_table.lookup` with the `CallSite` cache,
  replacing the Phase 5 direct lookup.
- `defprotocol` / `extend-protocol` / `extend-type` analyzer
  recognition activates; Tier A behaviour lands.

The rewrite is expected per ROADMAP §A25; principle.md depth 3 is
the typical depth (cross-file refactor of the `.method` call path).
depth 4 only if the protocol satisfaction model itself supersedes
this ADR.

## References

- ROADMAP §9.6 task 4.18 (protocol dispatch table skeleton),
  task 4.25 (method_table + CallSite cache skeleton)
- ROADMAP §9.9 (Phase 7 entry — protocol activation)
- ROADMAP §A25 (Existing code is mutable)
- Related ADRs: 0007, 0011

## Revision history

- 2026-05-23: Status: Proposed -> Accepted (initial landing).
- 2026-05-23 (amendment 1): Added "Phase 7+ migration note" section
  to narrate the rewrite of the Phase 5 dispatch path when task 4.18
  / 4.25 skeletons activate in Phase 7 (per ROADMAP §A25).

- 2026-05-26 (amendment 1 — Phase 7.1 implementation): Land
  `dispatch(rt, env, cs, receiver, protocol, method, args, loc)` in
  `src/runtime/dispatch.zig`. Signature differs from the original
  ADR sketch by including `env` + `loc` — `env` is required because
  `BuiltinFn` (= the protocol method impl signature) takes `env`,
  and `loc` is needed for catalog raise at the dispatch site.
  ROADMAP §9.9 row 7.1's shorter signature `(rt, cs, receiver,
  protocol, method, args)` is a sketch; this amendment finalises
  the full surface.

  Body wraps `CallSite.lookupWithCache` from
  `src/runtime/dispatch/method_table.zig:53-72` (which already
  caches the `last_type → last_method` slot with protocol+method
  name re-validation) + casts `TypeDescriptor.MethodEntry.fn_ptr`
  (`?*const anyopaque`) back to `BuiltinFn` + invokes. Raises
  new catalog Code `protocol_no_satisfies` (kind = `type_error`,
  phase = `eval`) when the receiver is not a `typed_instance`
  (per-Tag default descriptor table is a Phase 7+ extension) or
  when `lookupWithCache` returns null.

  **Devil's-advocate fork (depth-2, fresh context) verbatim
  embedding** — produced 3 alternatives within F-002 / F-007 /
  F-009 envelope:

  > **Alt 1 — smallest-diff**: ship dispatch ABI with
  > `lookupWithCache` as-is; defer `generation`. The existing
  > cache short-circuit re-validates protocol + method names on
  > every hit, so the only correctness gap is `extend-type`
  > *changing the impl* for a `(td, protocol, method)` triple a
  > CallSite already cached. In Phase 7.1, `extend-type` doesn't
  > exist yet (it's 7.7's burden). Until 7.7 lands, `generation`
  > invalidates nothing — it's a Phase 7.7 prerequisite shipped
  > 6 tasks early. Better: ships less surface in 7.1; the
  > cache-invalidation contract gets designed alongside its
  > consumer.
  >
  > **Alt 2 — finished-form-clean**: adopt the proposal's
  > invalidation semantics but **move the dispatch fn body to
  > `TypeDescriptor.dispatchMethod(rt, cs, receiver, protocol,
  > method, args)`** rather than a free function in
  > `runtime/dispatch.zig`. Co-locate with data; TypeDescriptor
  > becomes the dispatch authority.
  >
  > **Alt 3 — wildcard**: cw v0 textbook adoption — per-
  > ProtocolFn cache on the method-Var, not per-CallSite. Trades
  > per-Node arena allocation for cache slots living in heap-
  > Value Var bodies. Cache survives across same-method-different-
  > call-site re-evaluation. Breaks F-002 finished form: per-Var
  > caches share state across unrelated call sites — a polymorphic
  > call site at one location pessimises the monomorphic cache
  > that a tight loop elsewhere depends on. Per-CallSite is the
  > C2/V8 inline-cache convergence point; per-Var is one generation
  > behind.
  >
  > **Recommendation**: Alt 1 (ship dispatch ABI; defer
  > `generation` to 7.7 when `extend-type` lands). The existing
  > cache is already correct for same-type repeat-method calls
  > (the only call pattern 7.1 can test). Shipping `generation`
  > in 7.1 means designing the invalidation contract without
  > seeing its consumer — exactly the smell `principle.md` calls
  > Reservation-as-bias.

  **Selected**: Alt 1 verbatim (skip `generation` field in this
  amendment; ship with current `CallSite { last_type, last_method }`
  shape). Alt 2's co-location (`td.dispatchMethod`) considered
  but rejected — `runtime/dispatch.zig` is the natural home for
  the dispatch ABI (the file already contains `VTable.callFn` +
  threadlocal call-scoped state), and TypeDescriptor stays
  focused on data-side helpers (`lookupMethod` etc.). Alt 3
  rejected per the advocate's own F-002 finding (per-Var cache
  locality regression).

  Phase 7.7 amendment will add `generation: u32` to CallSite +
  `Runtime.protocol_generation: u32` + bump-on-extend-type
  semantics. Phase 7.7 also lands `extend-type` analyzer
  recognition (cw v1 has no `extend-type` / `extend-protocol` /
  `defprotocol` SPECIAL_FORMS today — `analyzer.zig:168` shows
  the table doesn't include them).

  3 new unit tests in `dispatch.zig` cover: cache miss + hit on
  typed_instance receiver; missing method → `protocol_no_satisfies`;
  non-typed_instance receiver → `protocol_no_satisfies` (raised
  as `error.TypeError` per catalog Code mapping). No e2e —
  `defprotocol` / `extend-type` analyzer surface lands at 7.3 /
  7.7; 7.1's dispatch ABI is validated via synthetic fn-pointer
  injection per the survey's recommended scope.

  ROADMAP §9.9 row 7.1 flips to `[x]`.
