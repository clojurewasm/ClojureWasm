# ADR-0094 — Reentrant Zig primitives root their accumulators via the EvalFrame chain

- **Status**: Proposed → Accepted (2026-06-05)
- **Amends**: ADR-0091 (operand-stack root + thread union) — adds a new
  *kind of producer* of `EvalFrame`s (Layer-2 primitives), not a new root
  source.
- **Driven by**: D-251 (GC root walk vs a real runtime env), surfaced by the
  D-250 torture mode.

## Context

cljw's precise mark-sweep GC (ADR-0028) walks per-thread roots via the
`EvalFrame` chain (ADR-0091): each `vm.eval` activation pushes a Zig-local
`EvalFrame { stack, sp, locals, parent }` onto a threadlocal head and
`defer`-pops it, so a collect at any safe point marks the live operand
Values `stack[0..sp]` + `locals`. The worker registry already exposes this
chain per thread via `eval_frame_slot`.

The D-250 torture mode (force a collect at every VM back-edge poll) revealed
that **Zig primitives that hold GC Values in Zig locals while re-entering
`eval` are a use-after-free class**. `reduceFn` (higher_order.zig) is the
exemplar: it keeps the accumulator `acc` and seq cursor `cur` in Zig locals
while it (a) calls the reducing fn via `invokeCallable` → VM `eval` and (b)
forces lazy/chunked seq elements via `firstFn`/`nextFn`/`seqFn` → VM `eval`.
A collect at a nested back-edge poll sweeps `acc`/`cur` (on no operand stack,
no `locals` slot, no trace) → corruption (e.g. `(vec (map str (range 1 80)))`
crashes reading a garbage vector `shift`). This is the same class as the
single-slot `gc_self_guard` (one in-flight fabrication value), generalised to
primitives holding *multiple* live Values across reentrant eval.

This affects the whole seq-realiser family: `reduce` (→ `vec`/`into`/
`interpose`/`mapv`/`frequencies`/…), the `map`/`filter` realisers, the
chunk-builder, `apply`-over-lazy, `sort`, etc. — wherever a Layer-2 primitive
drives a loop that re-enters eval while holding an accumulator/source.

## Decision

A reentrant Zig primitive that holds GC Values across a call back into `eval`
**publishes those Values by pushing a short `root_set.EvalFrame` onto the
existing threadlocal chain** (the same mechanism `vm.eval` uses), writing the
live Values into a Zig-local `[N]Value` operand array and updating them before
each reentrant call. No new root source, no new `ThreadGcContext` slot — the
existing root walk + worker exposure cover it for free.

`EvalFrame`'s meaning widens from "one `vm.eval` invocation's operand stack"
to "one operand-stack-resident root scope" (VM eval activation OR a reentrant
primitive's accumulator frame).

First application: `reduceFn` pushes a 2-slot frame `[acc, cur]`, refreshed
before every `invokeCallable`/`firstFn`/`nextFn`/`seqFn`. The remaining
seq-realiser primitives adopt the same 4-line `EvalFrame`-open as a campaign
(D-251), driven to torture-green big-bang per the `clj_diff_sweep` Discipline 2
("exhaustively-then-closed").

## Consequences

- **Positive**: zero new rooting infrastructure; one mechanism (`EvalFrame`)
  covers VM operands + primitive accumulators + workers uniformly (F-002
  finished-form, F-006 single non-moving heap walk). The pattern is a small,
  copy-paste-safe 4-line open per reentrant site. `gc_self_guard` becomes a
  candidate to fold into this shape later (one fewer special-case root source).
- **Negative / risk**: each reentrant site must remember to open a frame +
  refresh slots before each reentrant call (a `defer`-pop lifetime contract on
  a Zig-local array — get the refresh-before-call ordering wrong and the value
  is briefly unrooted). The torture mode is the mechanical guard that catches a
  missed site/refresh deterministically. Hot-path cost: a few threadlocal
  writes per loop iteration (accepted; perf is Release-measured separately,
  the algorithmic shape is unchanged).
- **Not chosen**: a parallel per-thread primitive-root stack (a second concept
  doing what `EvalFrame` does); a conservative C-stack scan (contradicts the
  precise mark-sweep ADR-0028 / F-006 and misses register-resident roots).

## Alternatives considered (Devil's-advocate fork, fresh context, verbatim)

> Recommendation: **Alternative B1** — reuse the existing `EvalFrame` chain;
> `reduceFn` opens a tiny operand-stack-resident frame holding `acc`/`cur` and
> `defer`-pops it, with a docstring/naming widening of `EvalFrame` from "one
> `vm.eval` invocation" to "one operand-stack-resident root scope."

**Alternative A — smallest-diff: a per-thread primitive-root *chain* (not a
fixed array).** Replace the draft's fixed `[K]Value` with a caller-stack-
resident linked `PrimRootFrame { roots: []Value, parent }` mirroring
`EvalFrame`. Better than the draft: unbounded depth at zero heap alloc (a
fixed `K` is an arbitrary cap that *will* be wrong for nested reducers).
Breaks/risks: still a brand-new root source — a second concept doing what
`EvalFrame` already does. F-clean.

**Alternative B — finished-form-clean: no new root source; publish onto the
EXISTING `EvalFrame`.** B1: `reduceFn` opens a 2-slot `EvalFrame` (`acc`,
`cur`) reusing `root_set.EvalFrame` verbatim — zero new types, walk code, or
worker slot (the `eval_frame_slot` already covers it). B2 (deeper): make
`reduce` VM-resident so `acc` lives in a `locals` slot — much larger surgery
that still must drive `firstFn`/`nextFn` reentrantly, so it doesn't escape the
shape. Better than draft: **zero new rooting infrastructure**; one mechanism
covers operands + accumulators + workers uniformly (F-002/F-006). Risk: B1
slightly widens `EvalFrame`'s "one `vm.eval`" docstring (a doc/naming fix);
the 2-slot array has the same `defer`-pop lifetime discipline as A. F-clean,
and the *most* aligned with F-006/F-002.

**Alternative C — wildcard: conservative C-stack scan for the reentrant
window.** Scan the native stack for bit-patterns that decode as in-heap
NaN-boxed pointers. Better: zero per-site wiring, zero per-iteration cost,
new primitives can't forget. Breaks/risks: **the leading would-violate
entry** — it grafts a *conservative* collector onto ADR-0028's *precise*
mark-sweep (which F-006 codifies): false-positive retention, no cheap heap
range-check on a GPA-backed non-moving heap (F-006), and register-resident
`acc` is *not on the stack* → missed roots → UAF worse than the bug. Cannot be
the primary mechanism; recorded as the wildcard, recommended against.

**Recommendation rationale**: F-002 (finished-form) + F-006 (one non-moving
heap, one walk) favour reusing `EvalFrame` over a parallel root source.
Picking the smaller-diff draft/Alt A over the F-clean B1 on cycle/LOC grounds
would be the Cycle-budget defer smell — re-pick B1. Per-iteration cost is 2
slot writes, identical across draft/A/B1; only the rejected Alt C avoids it.
Caveat carried into implementation: B1 must be applied as a **uniform
campaign** to every reentrant seq-realiser primitive (the `mapFn` collected
vector, filter/realiser loops, apply-over-lazy, sort) — a half-applied fix
leaves the same UAF class live in the unfixed primitives.
