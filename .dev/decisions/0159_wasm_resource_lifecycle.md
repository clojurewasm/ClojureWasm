# ADR-0159 — Wasm Component `resource` lifecycle: `own`-handle ownership + drop (D-404 Impl E)

- **Status**: Proposed → Accepted (2026-06-21, user-directed; D-404 Impl E resource ergonomics; DA-fork incorporated)
- **Driven by**: ADR-0135 Amendment 1's promise that a `:require`d Wasm Component's
  exports feel native — including WIT `resource`s. Today an `own`/`borrow` handle lifts to
  a bare integer; methods work (the `resource_counter` demo returns 6) but nothing ever
  runs the guest `resource.drop` destructor for an `own` handle → a **resource leak** for
  the lifetime of the component.
- **Relates to**: ADR-0135 (component-as-namespace), ADR-0158 (single-binary embed),
  F-001 (zwasm embedding), F-006 (mark-sweep GC; cljw heap ⟂ Wasm linear memory — separate
  spaces), F-016 (always-latest). External: zwasm `Opened.dropResource` (REQ-5).

## Context

A WIT `resource` (e.g. `resource counter { constructor(start:u32); increment:func()->u32;
get:func()->u32 }`) exports a constructor returning `own<T>` + methods taking `borrow<T>`.
cljw's `invokeTyped` lift currently maps `.own`/`.borrow` → `Value.initInteger(handle)`, so
a handle is an opaque integer the Clojure code threads back into method calls. This works
but:

- **Leaks**: nothing calls `resource.drop`, so the guest destructor never runs until the
  whole component is torn down (the `ComponentLoaded` box's GC finaliser runs
  `Opened.deinit()`, which frees the entire resource table — so there is no leak *across*
  components, only *within* a long-lived component holding many short-lived resources).
- **Untyped**: a bare integer carries no own/borrow distinction and no tie to its owning
  component — a handle from component A could be passed to component B's method.

zwasm already exposes the mechanism: **`Opened.dropResource(handle: u32)` (REQ-5)** runs the
declared destructor for an `own` handle (graph path only; a single-module component has no
resource table → `NoResourceTable`). Verified zwasm semantics (`resource_table.zig`):

- **Double-drop traps** (stale handle) — drop is NOT idempotent; the cljw wrapper must guard.
- **Handle indices are reused** (free-list) — a handle is opaque, single-use across drop,
  scoped to one `Opened`; cljw must never cache/compare a handle past its drop.
- **`own` vs `borrow`**: dropping an `own` runs the destructor; dropping a `borrow`
  decrements the lender's `num_lends`; an `own` can't be dropped while lent
  (`HandleStillBorrowed`). cljw reads own-vs-borrow straight from the WIT result type
  (`resolveFuncSig` → `.own`/`.borrow`).

(A mailbox note `from_cljw_05` asks zwasm to confirm these four points; all are read from
zwasm source, so the design proceeds on them — confirmation is a safety check, not a gate.)

## The crux — finaliser ordering hazard (cljw-side, NOT a zwasm concern)

cljw's GC is **mark-sweep, non-moving** (F-006), with NO guaranteed finaliser ordering
between two host objects collected in the same cycle. An `own`-handle wrapper whose GC
finaliser calls `componentBox.opened.dropResource(handle)` risks a **use-after-free**: if
the wrapper AND the `ComponentLoaded` box are both unreachable in one GC cycle and
`componentFinalise` (which `Opened.deinit()`s) runs first, the resource finaliser touches a
freed `Opened`. Rooting the component from the wrapper (hold the component handle Value in
`host_trace`-marked state) keeps the component alive while a resource is *reachable*, but
does not order the two finalisers when both are simultaneously garbage. The Decision below
picks the rooting + ordering mechanism.

## Decision

**Deterministic release is the contract; the resource wrapper's finaliser NEVER touches
zwasm state.** An `own` result becomes a typed wrapper; release is via a deterministic
`(wasm/resource-drop h)` / a `with-resource` scope (the Clojure-idiomatic `with-open`
pattern), and `componentFinalise`'s existing `Opened.deinit()` drains the whole resource
table at component teardown as the backstop. The wrapper roots its owning component (so a
held resource cannot outlive its `Opened`), but carries **no finaliser that calls
`dropResource`**.

Concretely:

1. **Wrapper**: an `own` result → a `.host_instance` (`resource_descriptor`) with
   `state = { component-handle Value (state[0]), raw handle u32 (state[1]), dropped-flag
   (state[2]) }`. `descriptor.host_trace` marks state[0] (the `ComponentLoaded` box Value),
   rooting the component while any resource is reachable — the java.util.Iterator
   cursor-rooting precedent (mark-only, non-moving GC; `gc_rooting.md §H`). **No
   `host_finalise`** on the resource wrapper.
2. **lower**: a wrapper passed to a `borrow`/`own` param yields state[1] (the raw handle);
   a wrapper whose dropped-flag is set raises a use-after-drop error before the call.
3. **release** (`(wasm/resource-drop h)` / `with-resource` exit): if not already dropped,
   reach the component via state[0] → `ComponentLoaded.opened.dropResource(state[1])` + set
   the one-shot dropped-flag (double-drop guarded cljw-side; `dropResource` would otherwise
   trap on the stale handle). Safe because the caller holds the wrapper, which roots the
   component → `Opened` is live at the call.
4. **backstop**: `componentFinalise` already runs `Opened.deinit()`, freeing the entire
   resource table — every un-dropped resource is released at component teardown.

### Divergence from the Devil's-advocate recommendation (the safety correction)

The DA recommended **C+** = `with-resource` + a **B′ registry where the resource wrapper's
finaliser deregisters-and-drops** ("valid because the rooting edge proves `Opened` is alive
at that instant"). **This per-resource-finaliser drop is NOT safe in cljw's GC** and is
therefore rejected: rooting via `host_trace` keeps the box alive only while the resource is
**reachable**; once the resource is garbage it no longer marks the box, so when a resource
and its component become garbage in the **same mark-sweep cycle**, both are swept together
with no ordering guarantee (the DA's own fact 4). At the resource finaliser's instant the
box may already be freed — so *any* box/`Opened` touch from the resource finaliser (drop OR
even "deregister", which dereferences the box's intrusive set) is a potential
use-after-free. The structurally safe form removes the resource finaliser entirely: the
wrapper holds the component Value by `host_trace` (a passive mark, no finaliser), release is
deterministic (held wrapper ⇒ live component), and the only GC-time drop is
`componentFinalise` draining its OWN table — exactly one finaliser, touching only state it
owns. The DA's deterministic-`with-resource`-is-the-finished-form thesis is adopted; only
its unsafe per-resource-finaliser path is dropped (this is a correctness divergence, not a
cycle/LOC downgrade — F-002 is upheld: the chosen form is *more* correct, not smaller).

### Scope / known limitation (documented, not a leak)

An individual resource that is GC'd **without** an explicit `resource-drop` / `with-resource`
is released at **component** teardown, not at its own death. For a long-lived component
minting many short-lived resources, use `with-resource` for timely release. This is the safe
trade vs. an unsafe finaliser; "GC drop" is honoured as *component*-GC drops all its
resources. The one-shot `(wasm/component-invoke …)` path (no cached component) keeps the
bare-integer lift for `own` results — there is no persistent component to own them; the
typed wrapper applies to the `require-component` / `component-call` cached-handle path.

## Alternatives considered

*(Devil's-advocate fork, fresh context, verbatim — the per-resource-finaliser-drop in its
B′/C+ is corrected in the Decision's "Divergence" note above.)*

> **Leading finding — no F-NNN is violated by any candidate.** A GC-finalizer drop touches
> only zwasm's `Opened` (zwasm's separate space, F-006), reached through a cljw-side pointer
> the resource wrapper already holds; it never traces Wasm linear memory into cljw's heap,
> never unifies the two spaces. F-001/F-006/F-016/F-002 are all satisfiable by every shape
> below. The real axis is **finalizer-ordering safety + idiomatic determinism**, not law.
>
> **(1) Smallest-diff — A, explicit-drop-only.** `own` becomes a thin wrapper host_instance
> holding `{component-handle Value, handle:u32, dropped-flag}`; `host_trace` marks the
> component Value; `(wasm/resource-drop h)` calls `opened.dropResource`, flips the one-shot
> flag; double-drop guarded cljw-side; NO finalizer drop. Leak bounded by `componentFinalise`'s
> full-table teardown. *Better*: zero finalizer-ordering surface — the hazard cannot arise.
> *Breaks*: contradicts ADR-0135's "GC drop"; a resource never explicitly dropped lives until
> *component* teardown — a long-lived component minting many short-lived resources accumulates
> dead handles.
>
> **(2) Finished-form-clean — B′, finalizer-via-registry (the box drops, not the resource).**
> GC-finalizer auto-drop, but the resource finalizer never calls `dropResource` directly;
> the `ComponentLoaded` box owns an intrusive set of live handles; the wrapper roots the box;
> the wrapper's finalizer only deregisters; `componentFinalise` drains the set before
> `opened.deinit()`. *Better*: true GC-lifecycle drop with the ordering hazard structurally
> dissolved — exactly one site touches `Opened`. *Breaks*: the per-resource immediate-drop-on-
> deregister path must prove the box is alive at that instant; double-drop guard still needed;
> the intrusive set must be freed; `HandleStillBorrowed` means a still-lent `own` can't drop.
>
> **(3) Wildcard — C+, `with-open`/`with-resource` deterministic scope + B′ backstop.**
> Primary path is `(with-resource [c (counter/new 5)] …)` dropping at scope exit
> (idiomatic, `with-open`-shaped); the GC-finalizer (B′) is best-effort for escapees.
> *Better*: deterministic release is the Clojure-idiomatic answer AND has a real backstop.
> *Breaks*: largest surface; scope-exit drop and the backstop must share the one-shot flag
> or double-drop; the macro needs a `try/finally` lowering.
>
> **Recommendation: adopt C+ layered on B′** (deterministic `with-resource` as the contract,
> registry-backed finalizer where the box drops). Per F-002 do NOT downgrade to A on
> diff/LOC grounds — A leaves "drop-when-the-value-dies" unsolved.
>
> **What the implementer must verify first:** that the fixture's only drop-observable signal —
> a method on a dropped handle *traps* — is reachable through cljw's catch surface as a
> deterministic assertable error, AND that the rooting edge keeps the box alive across a
> forced GC while a resource is reachable.

## Consequences

- Resources are released **deterministically** (`with-resource` / `resource-drop`) or at
  **component teardown** (the `Opened.deinit()` backstop) — no leak across components, and
  **no use-after-free** (no resource-finaliser → `Opened` path).
- An `own` handle is a **typed wrapper tied to its component** (can't be passed to another
  component's method); double-drop is guarded; use-after-drop raises a catchable error.
- **Limitation** (documented above): an un-scoped individual resource releases at component
  teardown, not at its own GC — `with-resource` is the timely path. One-shot
  `component-invoke` keeps the bare-int `own` lift.
- Implementation is incremental: **cycle 1** = the wrapper + `host_trace` rooting + lift/lower
  + `(wasm/resource-drop)` + the use-after-drop guard + the "method-on-dropped-handle traps"
  e2e; **cycle 2** = the `with-resource` macro sugar. Both deliver the same finished form;
  each is independently green.

## Affected files (when implemented)

- `runtime/cljw/wasm/component.zig` — the `own`-handle wrapper (`.host_instance` +
  `resource_descriptor` with `host_finalise`/`host_trace`); `lift`/`lower` changes to wrap
  an `own` result + extract the raw handle from a wrapper passed to a `borrow`/`own` param.
- `lang/clj/cljw/wasm.clj` — the surface (`require-component*` interns method Vars; a drop
  form / `with-open` per the Decision).
- e2e `phase16_wasm_require_component.sh` + a fixture — drop observed via "method on a
  dropped handle traps" (the `resource_counter` fixture has no drop-observable export).
