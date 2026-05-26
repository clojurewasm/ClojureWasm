# 0042 — `apply` variadic-callee fast-path: gated bind-direct in `callFunction` rest-pack

- **Status**: Accepted (Devil's-advocate fork landed 2026-05-27)
- **Date**: 2026-05-27
- **Author**: Shota Kudo (drafted with Claude autonomous loop)
- **Tags**: apply, variadic, dispatch, fn, lazy-seq, F-002, F-003,
  D-072, ADR-0036, ADR-0041

## Context

Phase 7 row 7.9 (D-072) refactors `apply` so the trailing seq is
not eagerly collected into a flat Zig slice when the callee is a
user variadic fn that can bind the seq directly to its `& rest`
parameter.

Today `applyFn`
(`src/lang/primitive/higher_order.zig:56-90`) walks the trailing
seqable via `seq → first/rest` into a `std.ArrayList(Value)`,
then dispatches via `rt.vtable.callFn` with a flat slice. The
walk fully realises lazy_seq cells and produces O(N) intermediate
Zig storage even when the callee is a variadic fn whose body
would happily walk the seq incrementally.

Row 7.9's Step 0 survey lives at
`private/notes/phase7-7.9-survey.md` (~640 lines incl. the
Step 0.6 main-agent amendment). The original survey framing
proposed an `IReduce` protocol fast-path on the trailing seq —
mirroring row 7.7 cycle 4's `reduceFn` IReduce bypass. The
Step 0.6 re-laying surfaced that this framing **does not match
JVM Clojure semantics**: JVM's `RestFn.applyTo`
(`OSS/clojure/src/jvm/clojure/lang/RestFn.java:132-160`) does
**variadic peel-and-pass-tail** using `RT.boundedLength` — IReduce
is consumed by `reduce`, not by `apply`. cw v0 also mirrors the
variadic shape (`collections.zig:961-1097` `__zig-apply` +
threadlocal `apply_rest_is_seq` flag at `dispatch.zig:64-67`).
The D-072 debt row body is amended in place per ROADMAP §17.4 to
reflect the corrected scope (variadic peel-and-pass-tail, not
IReduce on the trailing seq).

The substrate is in place:

- ADR-0041 (row 7.8) landed `FnNode.variadic: ?FnMethod`
  (`src/eval/node.zig:179-189`) and
  `tree_walk.selectMethod:790-797` already implements
  "prefer fixed-arity over variadic" (JVM rule 3).
- `tree_walk.callFunction:743-788` is the single rest-pack
  site: lines 765-777 cons-wrap `args[m.arity..]` into a fresh
  heap List for the `& rest` slot.
- VM has **no separate rest-pack**. `vm.zig:573` installs
  `tree_walk.treeWalkCall` as the VM's `vtable.callFn`; both
  backends share `callFunction`. The dual-backend parity
  contract (ADR-0036) is therefore satisfied by construction —
  no new analyzer Node variant, no new opcode.

The Devil's-advocate fork
(`private/notes/phase7-7.9-da-fork.md`, ~340 lines) enumerated
three alternatives within the F-001 / F-002 / F-003 / F-006 /
F-009 envelope plus one out-of-envelope pre-finding. The DA
recommendation is Alt 3 (gated bind-direct in `callFunction`).

## Decision

Adopt **Alt 3 — gated bind-direct rule inside
`tree_walk.callFunction`'s rest-pack step**. The dispatcher
contract (`rt.vtable.callFn` signature + entry count) is
unchanged.

### The rule

Inside `tree_walk.callFunction`, the rest-pack block at
lines 765-777 gains an early-bind branch:

> If `m.has_rest` AND `args.len == m.arity + 1` AND the single
> trailing arg `args[m.arity]` has a **seq-shaped tag** (one of
> `.list`, `.cons`, `.chunked_cons`, `.lazy_seq`, `.nil`) —
> bind that arg directly to the rest slot.
> Otherwise — fall through to the existing cons-pack loop.

The gate is generic — it does not look up whether the call
originated in `apply`. Any caller passing a single seq-shaped
arg into a variadic exact-arity slot benefits. The gate is
sound because cons-packing a single seq-shaped arg into a
one-element list would always be observably different from
direct binding only when the seq itself is the user-intended
single rest element — which the gate excludes by requiring a
seq-shaped tag (vectors are excluded; `(apply f x [y])` continues
to spread `[y]` element-by-element).

### `applyFn` change

`applyFn` is rewritten to its compact shape:

1. Validate arity (≥ 2) — unchanged.
2. Build `call_args = [leading..., trailing]` — a single
   contiguous slice of length `leading.len + 1`. The trailing
   slot holds the trailing arg as-is (no walk, no realisation).
3. Dispatch via `vtable.callFn(rt, env, f, call_args, loc)`.

When the callee is a variadic fn whose exact-arity matches the
shape (= `leading.len == m.arity` so `call_args.len == m.arity +
1`) AND `trailing` is seq-shaped, the gate fires and `trailing`
binds directly to `& rest`. Otherwise the callee's normal
arity-matching applies — for a fixed-arity callee, `call_args` of
length `leading + 1` won't match the fixed arity (unless
`leading + 1 == fixed_arity` in which case the trailing arg is
the user's single positional value, also correct), and the
arity error surfaces. For lazy / list / cons trailing args, the
direct bind happens. For vector trailing args, the gate skips,
the existing cons-wrap fires, the user's vector is wrapped into
a one-element list — wrong semantics for JVM compatibility.

To preserve JVM `(apply f x [y])` semantics (the `[y]` vector
spreads to a one-element list), `applyFn` retains a **vector /
non-seq spread step** as a pre-pass: if `trailing` is a vector /
hash-set / array-map / etc., walk it to spread into individual
`call_args` slots (same as today's eager path); only seq-shaped
trailings flow through the direct-bind opportunity. This keeps
the spread semantics observable while opening the lazy-tail
fast-path for the cases that benefit (list, cons, lazy_seq).

### Cycle structure

- **Sub-cycle 1 (this commit)**: ADR-0042 lands + D-072 debt
  row amended in place + Step 0.6 amendment recorded on
  `private/notes/phase7-7.9-survey.md`.
- **Sub-cycle 2**: implement the gated bind-direct rule in
  `callFunction:765-777` (≈12 LOC) + refactor `applyFn` to the
  compact shape (≈25 LOC net reduction). Add ≥ 3 differential
  test cases (positive: list / cons / lazy_seq tail with
  variadic callee; negative: vector tail still spreads) +
  e2e shell coverage.
- **Sub-cycle 3**: close row 7.9 — flip `[x]` in §9.9; per-task
  note; smell sweep.

## Implementation surface

| File                                      | Change                                                                               | LOC     |
|-------------------------------------------|--------------------------------------------------------------------------------------|---------|
| `src/eval/backend/tree_walk.zig`          | `callFunction` rest-pack gains the gated bind-direct branch + 5-line comment block   | ~12 LOC |
| `src/lang/primitive/higher_order.zig`     | `applyFn` rewritten to compact shape + vector-spread pre-pass                        | -15 LOC |
| `src/lang/diff_test.zig`                  | 3 positive cases + 1 negative case for vector-spread; locks the gate rule on both BE | ~40 LOC |
| `test/e2e/phase7_apply_variadic.sh` (new) | e2e cases: lazy-tail apply on variadic user fn                                       | ~30 LOC |
| `src/runtime/dispatch.zig`                | **untouched** — vtable contract unchanged                                           | 0       |

Net: roughly +67 LOC across 4 files, -15 LOC in higher_order.zig
for a net ≈ +52 LOC. No new Node variant, no new opcode, no
vtable surgery — `dual_backend_parity.md`'s contract is
satisfied by construction.

## Alternatives considered

(Devil's-advocate subagent output verbatim from
`private/notes/phase7-7.9-da-fork.md`; the subagent's
recommendation is Alt 3 and the main loop adopts it.)

### Pre-finding (out-of-envelope; recorded as leading entry per CLAUDE.md DA mandate)

**Value-tag-marker variant violates F-004 (NaN-box 64-slot
budget).** A new `Value.Tag` (e.g. `apply_rest_seq`) expressing
"this is a prebound seq for `& rest`" would give the cleanest
in-band signal — no shared state, no vtable widening, no
caller / callee coupling. But F-004 fixes the second-generation
layout at 4 group × 16 sub-type = 64 slot with ~10 slots
reserved for future surprises; burning one on a transient
round-trip marker is the inverse of the Reservation-as-bias
smell. **Excluded as F-004 violation.** Main loop does not halt;
the in-envelope Alt 3 is still live.

### Alt 1 — Smallest-diff: extend `callFn` signature with `prebound_rest: ?Value`

Widen `vtable.callFn` to a 6-parameter form, passing `null` from
the 7 of 8 existing call sites that have no use for the new
slot. `applyFn` peels leading args + passes the trailing seq as
`prebound_rest` for the variadic case.

- Surface: `dispatch.zig` (~3 LOC), `tree_walk.zig` rest-pack
  branch (~20 LOC), 8 call sites pass `null` (~8 LOC), `applyFn`
  (~40 LOC), diff cases. Total ~80 LOC.
- Better: single vtable entry remains canonical;
  discoverability via `rg "vt\.callFn"` stays single-list.
- Worse: **Smallest-diff bias smell per F-002.** Mutates the
  load-bearing dispatcher contract for a property meaningful
  at exactly one call site. Adds a per-call cost (extra param
  / null check) to every fn invocation.
- cw v0's threadlocal `apply_rest_is_seq` flag is rejected here
  for the same reason at a finer grain: literal smallest diff
  (zero signature change, zero call-site touches) but its
  finished form is "shared mutable state with temporal
  coupling" — cleaner finished form (no shared state) wins per
  F-002 regardless of diff size.
- **F-002: violates** (Smallest-diff bias). F-001 / F-003 /
  F-006 / F-009 neutral.

### Alt 2 — Finished-form-clean: rename + sibling vtable entry

Rename `vtable.callFn` → `callFnFlat`; add sibling
`callFnVariadic(rt, env, fn_val, leading, rest_seq, loc)`.
Names document the calling convention. Every existing site is
flat → mechanical 8-site rename. `applyFn` chooses between them
based on `f.tag() == .fn_val ∧ fn.variadic != null`.

- Surface: ~100 LOC + 8-site rename.
- Better: names self-document; no naming wart
  (`callFn` / `callFnWithPreboundRest` asymmetry); Phase 16
  zwasm v2 dispatch arm gets a clean `callFnFlat` entry.
- Worse: 8-site mechanical rename + every test fixture mocking
  `vtable.callFn` (`dispatch.zig:298`, `multimethod.zig:790`)
  needs updating; the rename ripple is non-trivially
  front-loaded; the cost is paid once but timing matters at a
  Phase mid-flight.
- **F-002: strongly positive** (finished form cleaner than
  Option C); F-001 / F-003: positive; F-006 / F-009: neutral.

### Alt 3 — Wildcard: move variadic-detect into the call-frame setup (ADOPTED)

(Full shape in the Decision section above.)

- Surface: ~12 LOC in `callFunction`, -15 LOC in `applyFn`, 0
  call-site touches, 0 vtable changes. **Net negative LOC.**
- Better than Option C / Alt 1 / Alt 2: zero vtable surgery;
  reuses an existing decision point (rest-pack); no new public
  entry; other callers benefit transparently; F-003 alignment
  (no structural-plan widening to defer).
- Worse: action-at-a-distance between `applyFn` and
  `callFunction` (mitigated by 5-line comment block + forward
  links + diff_test lock-in); narrow JVM-conforming-but-v0-
  divergent semantics on the multi-arity-with-empty-lazy-seq
  case (v0 realises the first cell to prefer the fixed arm; cw
  v1 binds the variadic arm with empty rest — arguably cleaner
  than v0's lazy-realisation-as-dispatch-side-effect smell).
- **F-002: positive**; **F-003: strongly positive**; F-001 /
  F-006 / F-009: neutral.

### Why ADR-0042 adopts Alt 3

1. **F-002 finished-form**: Alt 3's finished form is "the
   rest-binding step recognises an already-shaped seq and
   accepts it" — a single local refinement of one existing
   decision point. Option C / Alt 1 / Alt 2 all add structural
   surface area to handle a property that is really about
   call-frame binding.
2. **F-003 deferral**: Alt 3 is the only candidate that does
   not invoke F-003's "imagine + defer" cycle for a structural
   plan decision. Vtable widening would have to be re-walked at
   Phase 16 entry (zwasm v2 dispatch arm); the rest-pack rule
   lives inside `callFunction` and is invisible to Phase 16.
3. **Net negative LOC** — Alt 3 is the only candidate that
   shrinks the codebase. cw v0's `__zig-apply` was 138 LOC of
   apply + 70 LOC of helpers + threadlocal coordination; Alt 3
   collapses that to ~12 LOC in `callFunction` + ~15 LOC in
   `applyFn`.
4. **No new dispatcher surface to maintain**. Two vtable entries
   would set the precedent for a third (`callFnAsync`,
   `callFnInWasm`, `callFnWithCallSite`) at later Phases.
5. **The semantics divergence from cw v0 is acceptable**. The
   multi-arity-with-empty-lazy-seq case where v0 realises one
   cell to prefer the fixed arm is itself a smell (lazy_seq
   realisation as a side-effect of dispatch). cw v1 declares
   per P3 + F-002 that v0 design pressure is not binding; this
   is the canonical example.

## Consequences

### Positive

- `applyFn` becomes a compact spread-or-passthrough body;
  cw v0's threadlocal `apply_rest_is_seq` is not replicated;
  the cross-Zone temporal coupling that v0 carried disappears.
- Any caller (not just `apply`) passing a single seq-shaped
  arg to a variadic exact-arity slot benefits transparently.
- `vtable.callFn` shape stays uniform — Phase 16's wasm fn
  dispatch arm lands without an apologetic `prebound_rest`
  parameter.
- The dual-backend parity contract (ADR-0036) is satisfied by
  construction — no new analyzer Node variant, no new opcode.

### Negative

- Action-at-a-distance between `applyFn` and `callFunction`.
  Mitigated by a 5-line comment block in `callFunction`
  explaining the gated bind-direct case + a forward link from
  `applyFn`'s docstring + diff_test cases locking the rule.
- A narrow semantics divergence from cw v0 on the multi-arity-
  with-empty-lazy-seq case (v0 realises one cell to prefer the
  fixed arm; cw v1 binds the variadic arm with empty rest).
  JVM-conforming, v0-divergent. Documented + locked via diff_test
  case.
- The gate's tag set (`.list`, `.cons`, `.chunked_cons`,
  `.lazy_seq`, `.nil`) must be kept in sync with future seq-
  shaped tag additions (e.g. `.range`, `.string_seq`,
  `.array_seq` when those land as user-visible seqs). The gate
  becomes a forward-touched site for new seq tags.

### Deferred

- `IReduce` registration on `lazy_seq` TypeDescriptor (survey's
  original cycle 1 candidate). Step 0.6 amendment showed this
  has zero behavioural change vs the row 7.7 cycle 4 seq-walk
  fallback (and would be slower if written in `.clj`). Defer
  until a real consumer surfaces (e.g. chunked-lazy-seq with
  native realisation arithmetic, Phase 8+).
- `boundedSeqLength` as a public helper (survey DIVERGENCE 3).
  Alt 3 does not need length information; the gate keys on tag
  alone. Defer until a real consumer surfaces (multi-arity
  dispatch preference with lazy_seq trailing, spec validation
  shortcuts).
- The forward-touched-site cost on the gate's tag set is a
  future audit row candidate when `range` lands as a runtime
  fn (currently the heap tag exists but no `range` Var; row
  7.10+ or Phase 8 lazy-seq builders cluster).

## Cross-references

- ROADMAP §9.9 row 7.9 (this row's task table entry).
- D-072 (`.dev/debt.md`) — body amended in place per ROADMAP
  §17.4 to reflect the corrected "variadic peel-and-pass"
  scope (was framed as "IReduce aware path" pre-survey).
- ADR-0036 — dual-backend parity contract (satisfied by
  construction; no new Node / opcode).
- ADR-0041 — multi-arity `fn*` shape (`FnNode.variadic`
  substrate this ADR consumes).
- ADR-0008 — protocol dispatch unify (the IReduce path on
  `reduceFn` whose row 7.7 cycle 4 framing influenced
  D-072's pre-survey body — re-oriented by the Step 0.6
  amendment).
- F-002 (`.dev/project_facts.md`) — finished-form cleanliness;
  the rejection of Alt 1's smallest-diff path + cw v0
  threadlocal rides on this.
- F-003 — decision-deferral on structural plans; Alt 3 is the
  only candidate that does not require a Phase-16 re-walk of
  the vtable shape decision.
- F-001 — zwasm v2 integration (Phase 16); Alt 3 leaves
  `vtable.callFn` shape pristine for Phase 16 to extend on its
  own terms.
- `private/notes/phase7-7.9-survey.md` — Step 0 survey + Step 0.6
  main-agent amendment.
- `private/notes/phase7-7.9-da-fork.md` — Devil's-advocate
  enumeration; this ADR's "Alternatives considered" section is
  the DA output condensed.
- cw v0 `__zig-apply` at
  `~/Documents/MyProducts/ClojureWasm/src/lang/builtins/collections.zig:961-1097`
  + threadlocal at `src/runtime/dispatch.zig:64-67` — the
  divergence anchor.
- JVM `RestFn.applyTo` at
  `~/Documents/OSS/clojure/src/jvm/clojure/lang/RestFn.java:132-160`
  — the semantics anchor.
