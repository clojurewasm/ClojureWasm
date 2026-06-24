# ADR-0066 — `deftype` becomes a macro mirroring `defrecord` (retire the special form)

- **Status**: Proposed → Accepted (2026-06-01)
- **Discharges**: D-087 (deftype Name/->Name unbound + protocol body silently dropped)
- **Related**: ADR-0007 (TypeDescriptor / Option β), ADR-0041 (fn multi-arity),
  ADR-0050 (interop call node), `.claude/rules/dual_backend_parity.md` (ADR-0036),
  F-002 / F-009 / F-011, D-048 (catch-by-deftype-class, orthogonal)

## Context

`deftype` was a **special form** (`analyzer/special_forms.zig::analyzeDeftype`
→ `deftype_node` → `tree_walk::evalDeftype` / VM `op_deftype`). `analyzeDeftype`
parsed only `(deftype Name [fields])` and **silently ignored any protocol-impl
body** after the field vector — `(deftype T [v] IFoo (foo [_] ...))` "succeeded"
while dropping the `IFoo` impl (a permanent-no-op, forbidden by
`provisional_marker.md`). It also never bound the positional constructor `->Name`
(`(->T 42)` → "Unable to resolve symbol"), unlike JVM Clojure.

`defrecord` is **already a macro** (`macro_transforms.zig::expandDefrecord`)
lowering to `(do (def Name (rt/__defrecord! 'Name ['fields])) (def ->Name
(fn* [..] (Name. ..))) extend-type-sections...)`. deftype and defrecord differ
only in the registered `TypeDescriptor.kind` (`.deftype` vs `.defrecord`) and the
absence of map semantics for deftype — and the downstream map-protocol arms
already gate on `inst.descriptor.kind != .defrecord` (collection.zig:429/564/615),
so a `.deftype`-kind instance is correctly excluded from map behaviour.

A Devil's-advocate review (general-purpose subagent, fresh context, F-NNN-
constrained) also surfaced a **latent VM bug (BUG-1)**: the VM `op_deftype` arm
pushed nil and relied on a (false) "analyzer-time registerType" comment — a
deftype run on the VM backend ALONE never registered the type. The diff harness
masked this by running TreeWalk first on the same `rt` (state leak).

## Decision

Convert `deftype` to a macro `expandDeftype` mirroring `expandDefrecord`, and
**retire the special form**. Per the DA's correction, do NOT duplicate
`defrecordPrim`: extract a shared kind-parameterised registration helper that
both `rt/__defrecord!` and the new `rt/__deftype!` thunk into (F-011 — the two
primitives differ only in the `.kind` passed to `registerType`).

Removed (the deletion is fully enumerable; the VM's exhaustive `Opcode` / `Node`
switches make completeness compiler-enforced):

- `deftype` from the analyzer special-forms table + `deftype_form` enum tag +
  dispatch arm + `analyzeDeftype`.
- `deftype_node` from the `Node` union + `evalDeftype` (TreeWalk) + the VM
  compile arm + `op_deftype` (opcode enum + emit + VM dispatch).
- The false "analyzer-time registerType" comments.

The macro's `rt/__deftype!` call is a backend-neutral primitive (executed
identically by TreeWalk eval and VM `op_call`), so registration no longer splits
by backend — **BUG-1 is fixed as a side effect**.

## Consequences

- `(deftype Name [fields] Proto (m [..] ..))` now binds `Name` + `->Name` and
  applies the protocol impls via the shared `extend-type` lowering. clj-grounded.
- deftype gets NO map semantics (kind-gated) — matches JVM `deftype` vs
  `defrecord`.
- catch-by-deftype-class is unaffected: `host_class.isKnownException` scans a
  static list, never `rt.types` (D-048 remains the orthogonal open row).
- `(Name. args)` constructor still resolves via eval-time `rt.types.get` inside
  the macro's `(do ...)` — same ordering as before.
- A **VM-only** (fresh-`rt`) deftype test is added so the diff harness no longer
  masks backend-specific registration (dual_backend_parity test point 4).
- The analyzer unit test asserting `n.* == .deftype_node` is rewritten to assert
  macro expansion.

## Alternatives considered (Devil's-advocate output, verbatim summary)

- **Alt 1 — smallest-diff: keep the special form, parse the body + emit ->Name in
  `analyzeDeftype`.** Rejected: re-implements `expandDefrecord`'s entire
  extend-type lowering in analyzer/Node space — a direct F-011 violation
  (commonization outranks effort); leaves BUG-1 unfixed. Its only honest sub-
  variant (raise `feature_not_supported` for the body) is a strictly-worse
  transient stub than implementing it.
- **Alt 2 — finished-form: the macro conversion (CHOSEN).** Maximal F-011
  commonization (`expandDeftype`/`expandDefrecord` differ only in primitive name +
  `.kind`); F-009-clean; deletes a Node variant + opcode; incidentally fixes
  BUG-1. DA corrections folded in: (1) share a kind-parameterised registration
  primitive instead of a duplicated `__deftype!`; (2) verified the map-semantics
  gate keys on `.kind` not `field_layout`.
- **Alt 3 — wildcard: one `expandDefType(kind)` body + one kind-param primitive
  for BOTH deftype and defrecord.** Primitive-level unification adopted (the
  registration genuinely never diverges); macro-level unification rejected —
  defrecord grows map-only factory/assoc/`=`-by-fields that deftype must never
  have, so a single macro body would accumulate a `kind`-branch thicket. Two thin
  macro bodies sharing extracted helpers is cleaner than one branchy body.

DA recommendation (non-binding): Alt 2 with the shared kind-param primitive — the
main loop adopts exactly this. No F-NNN blocks any alternative; cycle/diff size
did not factor into the ranking.

## Amendment 1 (2026-06-25) — cross-section same-name-arity overload merge (D-530)

clj lets a deftype / defrecord / reify implement the same method NAME at
different arities across DIFFERENT protocol sections — `clojure.lang.Seqable`
`seq[this]` + `clojure.lang.Sorted` `seq[this asc]` (`NewInstanceMethod` keys
methods by `[name, arity]`). data.priority-map's `subseq`/`rsubseq` need it.
cljw already merged same-name arities WITHIN one protocol section into a
multi-arity `fn*` (D-279, in `expandExtendType` + inline in `expandReify`), but
two sections never met that grouping, so each emitted its own single-arity
method-table entry and the dot-form `(. inst seq true)` resolved the first
(arity-1) row → "Wrong number of args (2)…expected 1".

**Decision**: a cross-section merge in the lowering. `lowerDefType` (deftype +
defrecord) and `expandReify` each pre-scan all sections, grouping impls by method
name + a per-name section bitset; a name appearing in >1 section (popcount > 1)
emits its FULL arity set under EACH contributing protocol, so `expandExtendType`
/ the reify per-section builder produce the complete multi-arity `fn*` for each.
`MethodEntry` stays `{protocol_name, method_name, method_val}` (NO arity field —
F-004), `lookupMethod` stays first-match, the dot-form call path + BOTH backends
are untouched — `selectMethod` already dispatches a multi-arity fn by arg count,
and the fix is in macro lowering (upstream of the analyzer Node split), so
TreeWalk + VM get it identically (no VM-DEFER). One file pair, lowering-only,
reusing the proven D-279 multi-arity-fn path.

**Risks (DA-surfaced, resolved):**
- *Same-arity duplicate* (two clauses, identical arity, which clj rejects
  "Duplicate method name&signature"): already caught — the merged `(fn* …)` hits
  the existing multi-arity validator "can't have two overloads with same arity",
  so cljw errors too. **F-011 accept/reject parity holds** (verified both sides).
- *Per-protocol fn duplication*: the merged fn registered under two protocols is
  two `MethodEntry` rows holding the SAME heap-fn handle — F-004's 8-byte Value
  is non-owning, GC traces the fn once, no double-free. Benign by construction.
- *Arity-surface widening* (Sorted's arity-2 `seq` also reachable via the Seqable
  entry): only the dot-form (null-protocol, arg-counted) reaches the union arity;
  no cljw protocol-fn is multi-arity, so a `(seq inst)` protocol call still
  selects arity-1 — the widening is unobservable. Protocol MEMBERSHIP is tracked
  separately (`protocol_impls` / `declaresProtocol`), not inferred from the shared
  method row, so sharing the fn does not make Sorted "satisfy" Seqable.
- *reify scope*: reify has the same gap and clj allows the overload on reify too,
  so fixing only deftype/defrecord would be a finished-form asymmetry (F-002). The
  same cross-section merge is applied to `expandReify` in the SAME cycle.

### Amendment 1 — Alternatives considered (Devil's-advocate output)

A fresh-context `general-purpose` DA was briefed with the active F-NNN envelope
(F-004 uniform Value slot / F-009 neutrality / F-002 finished-form / F-011 parity
/ ADR-0008 am3 method_val convergence) and produced three shapes:

- **Alt 1 — smallest-diff: the chosen merge + a per-protocol arity filter + a
  same-arity error.** Closes the widening by filtering each protocol's entry to
  its own declared arities, but to keep the dot-form's union it must add a
  synthetic fallback row OR a `selectMethod` arity-miss-fallthrough — i.e. it
  reaches into the dispatch path anyway, while leaving "is Seqable's seq arity-1
  or 2?" answered by whichever workaround.
- **Alt 2 — finished-form (DA-recommended): one canonical multi-arity fn per
  method NAME (interned once), with the protocol-fn surface routed through the
  same shared `selectMethod` as the dot-form**, so F-009 ("reachable identically
  from every surface") holds by construction rather than by current wiring.
  Bigger diff (touches `dispatch.zig`); the DA recommended it citing F-002.
- **Alt 3 — wildcard: leave lowering untouched, make `lookupMethod`/`selectMethod`
  arity-aware at the dispatch layer** (return all same-name rows, pick by argc).
  Most faithful to clj's `[name,arity]` keying and never widens a protocol's
  surface, but it pushes work into the dispatch hot path and creates a split-brain
  (within-section → merged fn at lowering; cross-section → arity-lookup) unless
  the within-section D-279 path is ALSO migrated — a much larger change.

**Main-loop decision (within the F-NNN envelope; DA recommendation is
non-binding):** keep the lowering-merge (the chosen design ≈ the DA's "Option A"),
NOT Alt 2. The DA's case for Alt 2 rests on the arity-surface widening being an
F-009 weakness; but the widening is **unobservable** (no cljw protocol-fn is
multi-arity, so only the arg-counted dot-form reaches the union arity, where
by-argc dispatch is correct), and protocol membership is tracked independently of
the method table — so Option A satisfies F-009 in practice, not merely "by current
wiring". Adopting Alt 2's `dispatch.zig` changes for a non-manifesting concern is
over-reach, not finished-form. The two DA risks that ARE real were both addressed:
the same-arity duplicate already errors via the `fn*` validator (F-011), and reify
is fixed in the same cycle (F-002 symmetry). Alt 3 is rejected as a split-brain
absent migrating the within-section path too.
