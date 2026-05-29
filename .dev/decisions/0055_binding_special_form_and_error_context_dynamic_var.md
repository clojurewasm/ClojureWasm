# 0055 — `binding` special form + cw v1's first dynamic var (`cljw.error/*error-context*`) + error-context capture

**Status**: Accepted (Devil's-advocate fork landed 2026-05-29)
**Date**: 2026-05-29
**Author**: Shota Kudo (drafted with Claude autonomous loop)
**Tags**: dynamic-var, binding, special-form, error-context, with-context, F-002, F-004, F-009, D-075, D-141-sibling, row-14.13

## Context

Row 14.13 deliverable (3) is `cljw.error/with-context`: `(with-context
{:request-id … :trace-id …} body)` stacks a context map on a dynamic
var; when an error event is emitted (EDN render in
`src/app/error_render.zig::formatErrorEdn`) the merged map's keys become
top-level event fields.

A Step-0.6 re-lay (survey `private/notes/phase14-14.13-binding-survey.md`
§9) found the handover's "narrow prerequisite = just the `binding`
special form" **wrong on a load-bearing point**:

- cw v1 has **ZERO production dynamic vars**. The dynamic-binding runtime
  machinery is fully built (`env.zig`: `BindingFrame`, threadlocal
  `current_frame`, `pushFrame`/`popFrame`/`findBinding`, `Var.deref`
  consulting the chain when `Var.flags.dynamic`), and both backends honor
  `DefNode.is_dynamic → Var.flags.dynamic` — but `analyzeDef` NEVER sets
  `is_dynamic` from surface syntax, and `^:dynamic` reader metadata is
  unimplemented (`(def ^:dynamic *x* 1)` → "def expects 1 or 2 args, got
  3"). Surface `^:keyword` metadata = **D-075** (a ~500-LOC Phase-7+
  feature) and is **F-004-entangled** (per-value metadata NaN-box slot is
  "未確定, decided at Phase 5 entry").
- So `with-context` needs cw v1's **first dynamic var**, and the natural
  `(def ^:dynamic *error-context* {})` will not parse.
- `binding` is also unimplemented (absent from the analyzer special-form
  set; `pushFrame`/`popFrame` have zero production call sites).
- Read-side constraint: the `binding` frame is popped (Zig `defer
  popFrame`) as an error unwinds, so by render time the frame is GONE —
  the context must be snapshotted **at raise time** while the frame is
  live. And `catalog.zig::raise(comptime code, location, args)` has **no
  `rt`/`env` access** (verified) — it only populates the threadlocal
  `Info`. So an Env-scoped slot reachable from raise is infeasible
  without rippling raise's signature across ~100 call sites.

## Decision

### D1: `binding` is a real special form (`BindingNode`), not a macro-transform

Diverges from JVM (a `defmacro` over `push-thread-bindings`/try/finally)
AND cw v0 (`transformBinding` macro). cw v1's analyzer special-form set +
dual-backend Node contract make a dedicated `binding_node` the
finished-form-clean shape: no dependency on a `var`/`hash-map`/`try`
macro chain, no per-call hash-map Value allocation, dynamic-var
resolution at analysis time. (ROADMAP A2 "features via the analyzer
surface" + F-002.)

- **Analyzer** (`bindings.zig::analyzeBinding`): even-position symbols
  resolve to their existing `*Var` (same qualified/alias/current-ns path
  as `analyzeSymbol`), NOT a lexical slot; odd-position init-exprs analyze
  in the OUTER scope (JVM parallel-eval); body analyzes in the same scope.
- **TreeWalk** (`evalBinding`): stack `BindingFrame`, eval inits in outer
  `locals`, validate each target `flags.dynamic` (else raise the new
  catalog Code), `pushFrame` + `defer popFrame()` (Zig defer = JVM
  finally), eval body.
- **VM** (real arm, no VM-DEFER — per F-002 + the handover's explicit
  "analyzer + tree_walk + vm" scope): two opcodes
  `op_push_binding_frame` / `op_pop_binding_frame`, compiled in the
  `try { push; body } finally { pop }` shape (the binding's own cleanup
  handler always pops the frame before an exception escapes its extent,
  reusing the existing `op_push_handler`/`op_pop_handler` unwind — so no
  threadlocal dangle on uncaught throw, and no new unwind path). The VM
  shares `env.zig`'s threadlocal `current_frame` (single-threaded per
  session), keeping `Var.deref` backend-agnostic.
- **Validation**: new catalog Code `binding_target_not_dynamic` ("Can't
  dynamically bind non-dynamic var: ns/name", JVM-faithful text per
  `error_catalog_only.md`), raised at eval/push time (JVM-faithful site).

### D2: cw v1's first dynamic var = Zig-registered `cljw.error/*error-context*`

`*error-context*` is interned at bootstrap into the `cljw.error` ns with
`flags.dynamic = true` set directly (no `MetadataMap` change, no reader
metadata, no F-004 value-metadata touch), root `{}`. System dynamic vars
being Zig-registered is the finished form (JVM's `*out*`/`*ns*` are
bootstrap-created clojure.core vars); this is NOT a stopgap. **User-facing
`^:dynamic`** (so users mark their OWN dynamic vars) stays deferred to
D-075 — with-context does not need it, and when D-075 lands NOTHING about
with-context changes (it was already `binding` over a real dynamic var).

### D3: read-side = global `*Var` slot + raise-time snapshot into `Info.context` + render via `printValue`

- A `?*const Var` slot in `runtime/error/` (next to the other error
  threadlocals), set when `*error-context*` is registered.
- `setErrorFmt`/`raise` snapshots `slot.?.deref()` into a new
  `Info.context: ?Value` field (default null) **at raise time** (frame
  live). Non-map / empty-map → leave null.
- `formatErrorEdn` (Layer 3) iterates `info.context`'s map entries and
  emits each `key value` pair as a top-level EDN field, rendering via the
  **canonical `runtime/print.zig::printValue`** (exists; Layer 0) — NOT a
  second hand-rolled printer.
- The slot is a **process-global**, not Env-scoped: raise has no env
  access (an Env-scoped slot would ripple raise's signature across ~100
  sites). For the single-Env CLI path (the only path that renders EDN
  error events — nREPL returns errors to the client, bypassing
  `renderError`) this is correct. The multi-Env-nREPL-EDN-error case is
  recorded as **D-142**.
- Field is **specific `Info.context`**, not a generic `Info.data`
  ex-info payload: ex-info `Info`-integration is not scoped here and a
  generic field would over-fit a not-yet-landed shape (Reservation-as-bias
  per F-002). It can generalize when ex-info `Info`-payload lands.

### D4: `with-context` = thin `.clj` macro over `binding`

New ns `cljw.error` at `src/lang/clj/cljw/error.clj` (new
`src/lang/clj/cljw/` dir) + an `@embedFile` row in `bootstrap.zig` FILES
after `core.clj` (needs `merge`/`defmacro`/`binding`). The `*error-context*`
Var is Zig-registered into the same ns before/at load.

```clojure
(in-ns 'cljw.error)
(defmacro with-context [ctx-map & body]
  `(binding [*error-context* (merge *error-context* ~ctx-map)] ~@body))
```

`merge` against the current `*error-context*` gives the stacking
(nested with-context accumulate). Reached as `(require [cljw.error :refer
[with-context]])` (F-009: `cljw.*` is the cljw-original ns family).

## Alternatives considered

(Devil's-advocate subagent, fresh context, F-NNN envelope — output
verbatim. The DA assumed raise could reach `rt.env`; the main loop
verified it CANNOT, which is why D3 takes the process-global slot rather
than the DA-recommended Env-scoped slot.)

> **F-NNN clearance for all three:** none violates an F-NNN. All avoid
> touching NaN-box layout / per-value metadata / `with-meta`/IObj
> (F-004), keep impl namespace-neutral with `cljw.error` as a thin
> Clojure-ns surface (F-009), and ship a working read-side (no forbidden
> no-op). The `binding` special form lands in all three. The decision is
> purely the var-creation + snapshot wiring.
>
> **Alt 1 — Smallest-diff: Zig-registered var, raise snapshots into
> `Info.context: ?Value`.** Error subsystem stores the `*Var` in a
> global/threadlocal slot; `raise` reads `if (ctx_var) |v| info.context
> = v.deref()`. `info.zig` already imports `Value` (layering clean).
> `formatErrorEdn` walks the map → top-level EDN keys. *Better:* smallest
> moving surface; the Var-pointer-in-error-subsystem slot dissolves the
> Layer-3↔Var coupling. *Breaks:* (1) a global `*Var` slot is
> process-wide mutable state — a second Env (nREPL) races on it; should
> be threadlocal/Env-scoped. (2) a `deref()`+field-set on EVERY raise
> (incl. ~100 internal raises with no context) is an always-on cost. (3)
> the EDN map-walk still needs a Value→EDN printer; `error_render.zig`
> has none — real work the proposal hand-waves.
>
> **Alt 2 — Finished-form-clean: generic `Info.data: ?Value` +
> Env-scoped dynamic-var registry; render via the canonical Value EDN
> printer.** Same Zig-registered var, but (a) an `Env.system_vars`
> registry (home for every future Zig-owned dynamic var `*out*`/`*ns*`/
> `*print-length*`) reached via `rt.env` so multi-session is correct by
> construction; (b) `Info.data` as a generic ex-info-style payload, not a
> context-specific field; render through the canonical Value→EDN printer
> cw needs anyway. *Better:* this is where the finished form lives — Alt
> 1's error-only slot gets unwound the moment `*out*` arrives
> (Reservation-as-bias); `Info.data` matches cw's ex_info direction;
> forcing the canonical printer kills the duplicate-printer smell;
> multi-session correctness falls out. *Breaks:* substantially larger;
> the system-var registry is a structural-plan touch that F-003 says to
> imagine-and-defer to the owning Phase (10/15 owns `*out*`); routing
> through the canonical printer may pull its scheduling forward;
> `Info.data` risks over-fitting a guessed ex-info shape (premature
> reservation) — UNLESS the registry is scoped to just `error_context`
> today (one field), barely larger than Alt 1 but multi-session-correct.
>
> **Alt 3 — Wildcard: no `Info` field — render-time deref through an
> error-subsystem callback.** Keep `Info` a pure scalar; install a
> `?*const fn() ?Value` provider; to beat frame-already-popped, capture
> the live frame pointer at raise and deref lazily at render. *Better:*
> most decoupled; `Info` stays Value-free; generalizes to "any subsystem
> contributes EDN fields". *Breaks:* capturing the stack-allocated
> frame pointer for later deref is a use-after-return; to be safe you
> must snapshot the VALUE at raise anyway — at which point the callback
> buys nothing over a field and adds a hop + the same global-slot race.
> Highest complexity, lowest payoff.
>
> **Recommendation (non-binding):** Alt 2 scoped down to one field —
> Zig-register `*error-context*`, reach it from raise via an Env-scoped
> slot (NOT process-global), snapshot `deref()` at raise into a generic
> `Info.data: ?Value`, render via the canonical Value→EDN printer. Do NOT
> build the full system-var registry now (F-003 defer — one
> `Env.system_vars.error_context: ?*Var` field is enough; debt-row the
> generalization). The two clean wins independent of the field's name:
> Env-scoped slot (kills the multi-session race) + canonical printer
> (kills the duplicate printer).

## Selection rationale

Took Alt 1's **var-creation mechanism** (Zig-registered system var) + the
DA's **canonical-printer** clean win (`printValue` exists — feasible),
and **rejected** the DA's Env-scoped-slot recommendation on a fact the DA
could not see: `catalog.zig::raise` has **no `rt`/`env` parameter**, so an
Env-scoped slot is unreachable from the snapshot site without a
~100-site signature ripple — disproportionate, and the EDN-error path is
single-Env (CLI) in practice (nREPL bypasses `renderError`). The
multi-Env race the DA flagged is therefore latent, not manifest; recorded
as **D-142** for the nREPL-EDN-error owner.

Rejected the DA's generic `Info.data` for a **specific `Info.context`**:
ex-info `Info`-payload is not scoped here, and a generic field would be a
Reservation-as-bias bet on a not-yet-landed shape (F-002). Rejected the
full `Env.system_vars` registry per the DA's own F-003 caveat — but since
the slot can't be Env-scoped anyway (raise has no env), the registry
question is moot for this cycle.

This shape is finished-form-clean for the with-context FEATURE: when
D-075 lands user `^:dynamic`, with-context is unchanged (it was already
`binding` over a real dynamic var; `*error-context*` stays Zig-registered
like `*out*`). A primitive push/pop with-context (no dynamic var) would
be unwound by that finished form = smallest-diff bias, so it was rejected.

## Consequences

- cw v1 gains its first dynamic var + the general `binding` special form;
  `binding` is dogfooded by with-context.
- The VM gains a real `binding` arm (not VM-DEFER) — the first
  control-construct beyond `try` to share the handler-unwind machinery.
- `Info` gains an optional `context` Value field; `formatErrorEdn` gains
  a context-merge loop (only the `edn` format carries structured fields;
  `text` is unaffected).
- Process-global `*error-context*` `*Var` slot: correct for CLI, latent
  multi-Env race recorded as D-142.
- User-defined `^:dynamic` stays deferred to D-075; `binding` only works
  on system (Zig-registered) dynamic vars until then.

## Affected files

- `src/eval/node.zig` (+`BindingNode`, union arm)
- `src/eval/analyzer/analyzer.zig` (special-form set + dispatch)
- `src/eval/analyzer/bindings.zig` (`analyzeBinding`)
- `src/eval/backend/tree_walk.zig` (`evalBinding` + node switch)
- `src/eval/backend/vm/opcode.zig` (+2 opcodes)
- `src/eval/backend/vm/compiler.zig` (`compileBinding`)
- `src/eval/backend/vm.zig` (dispatch arms + binding-frame stack)
- `src/runtime/error/catalog.zig` (+`binding_target_not_dynamic`)
- `src/runtime/error/info.zig` (+`Info.context` + `*error-context*` Var slot + snapshot)
- `src/app/error_render.zig` (`formatErrorEdn` context merge via `printValue`)
- `src/lang/clj/cljw/error.clj` (new — `with-context`)
- `src/lang/bootstrap.zig` (embed row + `*error-context*` registration)
- `src/lang/diff_test.zig` (+`binding` case)
- `test/e2e/phase14_binding.sh` + `test/e2e/phase14_with_context.sh` (new)
- `.dev/debt.md` (D-142 multi-Env nREPL EDN-error context slot)

## Revision history

- 2026-05-29 created: row 14.13 (3) re-lay after the Step-0.6
  prerequisite-gap finding (no production dynamic var; `^:dynamic`
  reader metadata = D-075, F-004-gated). Devil's-advocate fork landed.
