# ADR-0112 — typed_instance metadata (`with-meta`/`meta` on records)

- **Status**: Proposed → Accepted
- **Date**: 2026-06-07
- **Discharges**: D-312 (with-meta on typed_instance)
- **Cross-refs**: ADR-0110 (symbol value-metadata — the precedent mirrored),
  F-002 (finished-form), F-011 (clj behavioural equivalence), F-013
  (definition-derived capability); `private/notes/stage14-typed-instance-meta-survey.md`

## Context

`(with-meta <record-or-deftype-instance> m)` raised `with-meta: cannot attach
metadata to typed_instance`. In clj a **defrecord always implements IObj**
(records carry metadata for free, in a hidden `__meta` field); a plain
**deftype** does NOT unless it declares `clojure.lang.IObj`, and a `with-meta` on
a non-IObj deftype is a ClassCastException. cljw's `TypedInstance` had no instance
meta field; `metadata.zig`'s `.typed_instance` arms dispatched ONLY to a user
`IObj/-with-meta` impl, so a record with no hand-written IObj impl hit the error.

Surfaced exercising **clojure.data.zip** via `cljw -M:verify` (its `descendants`
attaches metadata to a zipper instance). It blocks any record-using library that
carries metadata.

clj semantics to match (verified): `(meta (->R 1))` → nil; `(meta (with-meta
(->R 1) {:x 1}))` → `{:x 1}`; `(= (->R 1) (with-meta (->R 1) {:x 1}))` → **true**
(meta NOT part of record value equality); `(identical? (->R 1) (with-meta (->R 1)
{:x 1}))` → false; a non-IObj deftype → throws.

## Decision

Mirror the ADR-0110 symbol-meta pattern, adapted for the record case
(**Shape α**, native field):

1. **`TypedInstance` gains `meta: Value = nil_val`** (`type_descriptor.zig`,
   appended to the extern struct — `header` stays at offset 0). `allocInstance`
   inits it nil (a freshly-constructed record has no meta).

2. **`instWithMeta` mints a FRESH instance** sharing the descriptor + the new
   meta. **The field array is COPIED, not shared** — `field_values_ptr` is
   `gc.infra`-owned and freed by `finaliseTypedInstance`, so two instances
   sharing one pointer would double-free on sweep. This is the **one divergence
   from the symbol `withMeta`** (symbols safely share interner-owned ns/name
   slices; records must copy). `(identical? r (with-meta r m))` → false.

3. **`metadata.zig` `.typed_instance` arms are kind-gated.** A user `IObj`
   `-meta`/`-with-meta` impl is consulted first (honours an explicit
   `(extend-type R IObj …)`); else:
   - `meta` → the native field (`instMetaOf`; nil when unset — `meta` never
     throws, even on a non-IObj deftype).
   - `with-meta` → if `descriptor.kind == .defrecord`, mint via `instWithMeta`;
     otherwise raise `.with_meta_target_not_iobj` (= clj ClassCastException for a
     non-IObj deftype). Records always; plain deftypes only via an explicit IObj
     impl (the dispatch path above).

4. **`reify` (`.reified_instance`) stays IObj-dispatch-only.** `ReifiedInstance`
   is a fixed 16-byte struct with no field tail and no place to store a re-minted
   instance's fields; a reify gets meta only via an explicit `(reify IObj
   (-with-meta …))`. A native field is deliberately NOT added to reify (scope line).

5. **GC trace marks the meta map** (`traceTypedInstance` gains one line, mirroring
   `traceSymbol`). **No membrane flip, no new registration** — `.typed_instance`
   is already GcManaged and already has a registered trace (strictly less GC work
   than the symbol case, which needed both).

6. **Equality/hash unchanged.** `typedInstanceEqual`/`typedInstanceKeyEq`/the
   `.typed_instance` `valueHash` arm walk descriptor + fields only, never a meta
   field, so `(= r (with-meta r m))` → true falls out by construction. (The symbol
   case needed `symbolStructEq` because interned identity was pointer-eq; records
   were already field-structural.)

7. **Record structural ops thread the source meta** (the DA's load-bearing
   finding, adopted same cycle — see Alternatives Alt 2). `(meta (assoc (with-meta
   r m) :k v))` → `m`, clj-faithful. The record `assoc` re-mint site
   (`collection.zig:618`) calls `allocInstanceMeta(…, inst.meta)` instead of
   `allocInstance` (meta-nil); `update` rides `assoc`. This was NOT deferred:
   shipping `with-meta` while `assoc` silently drops meta is a "ships a lie" smell
   (the user's divergence-suppression priority + F-011), and the cost is one
   `Value` argument on an alloc call already in that function. The only re-mint-
   from-existing site is the record `assoc` path; every other `allocInstance`
   caller constructs a FRESH instance (meta correctly nil). Mutable-deftype
   `set!`/`assoc` is in-place (same instance → meta preserved naturally).

## Alternatives considered (Devil's-advocate, fresh-context subagent, verbatim)

> I verified the load-bearing facts against source: **Residual (d) confirmed** —
> record `assoc` (`collection.zig:613-618`) ends in `allocInstance` which nil-inits
> `meta`, so `(meta (assoc r :k v))` → nil even after `with-meta`; the drop is real,
> unconditional, on the hot record-update path. **Copy reasoning confirmed** —
> `finaliseTypedInstance` frees `field_values_ptr`; sharing would double-free
> (forced by F-006, not convenience). **Reify** is a fixed extern struct, no field
> tail — point (4)'s scope line is structurally honest.
>
> **Alt 1 — smallest-diff: native field, but gate `with-meta` on
> `declaresProtocol("IObj")` for both kinds instead of `kind == .defrecord`.**
> Better: one uniform predicate; a `(deftype T … clojure.lang.IObj …)` that declares
> IObj but writes no `-with-meta` body gets native storage for free, matching clj's
> "declares IObj ⇒ carries __meta" more faithfully than "must hand-write -with-meta".
> Breaks: needs the defrecord macro to stamp an IObj declaration + `declaresProtocol`
> reachable from metadata.zig; if a deftype declares IObj AND writes `-with-meta`,
> dispatch-first must still win (both branches kept). Does NOT address (d).
>
> **Alt 2 — finished-form-clean (recommended): native field + thread `meta` through
> the record structural-op path in the SAME cycle (close residual (d)).** Change
> record `assoc`/`update`/`dissoc` to thread `old.meta` into the re-minted instance,
> as the persistent collections already do. Better: ships the WHOLE IObj contract
> for records — `(meta (assoc (with-meta r {:x 1}) :a 5))` → `{:x 1}` matches clj.
> This is the F-011 / F-013 definition-derived shape: "records are IObj" means meta
> survives structural ops, part of the definition, not a follow-up. The draft's
> split ("core with-meta now, threading = D-313") is the Ad-hoc-pass smell inverted
> onto a time axis — it ships the recognised-capability surface while silently
> dropping a definition-mandated behaviour on the most common record operation
> (update). Cost is tiny: the field-copy alloc already happens in assoc; threading
> meta is one extra `Value` to the alloc call. No F-NNN blocker, no new tag (F-004),
> no extra GC work beyond the meta-mark the draft already adds. Breaks: touches
> assoc/update/dissoc (a handful more sites) — per F-002 + Cycle-budget-defer smell,
> "more sites" is NOT a reason to defer. The extend-type `Associative` slow path
> returns the user impl's value and can't thread meta the same way — out of scope by
> construction (document, don't block).
>
> **Alt 3 — wildcard: side meta-table keyed by instance pointer (no struct field).**
> Better: zero struct-layout change; reify + record share one mechanism; no per-
> instance 8-byte cost for the majority of records that never carry meta. Breaks: a
> GC nightmare under F-006 — the map either roots every meta'd instance forever
> (leak) or needs a finaliser hook deleting entries + the map value traced as a
> SECOND root source. Reintroduces the pointer-keyed-side-table fragility the
> project avoids. The native field is strictly cleaner under non-moving mark-sweep:
> meta lives inside the traced object, no auxiliary root set. **Reject** — trades a
> bounded 8-byte field for an unbounded GC-rooting surface (F-002/F-006 inversion).
>
> **Recommendation: Alt 2.** The native-field choice is correct under F-006 (the
> draft gets that right; Alt 3 rejected). The discriminator (Alt 1) is a minor
> refinement, not load-bearing. The load-bearing finding is **(d): deferring
> assoc-meta-threading to D-313 IS a "ships a lie" smell** — `(assoc r :k v)` runs,
> returns a record, and `(meta …)` → nil with no error: the permanent-no-op /
> Ad-hoc-pass pattern `provisional_marker.md`'s 4th row forbids (no PROVISIONAL
> marker, user-observable dropped semantics). Worse than the symbol/collection
> precedents because record assoc/update is the PRIMARY way records are used. Cost
> to close: one extra `Value` arg on an alloc already in that function. Per F-002 +
> F-011 + Cycle-budget-defer smell, "it's a follow-up" is not a valid deferral. If
> the loop keeps the slice, the minimum honesty bar is a PROVISIONAL marker + AD/pin
> on the current nil behaviour — but the clean answer is Alt 2: thread the meta now
> and delete D-313.

**Main-loop disposition: ACCEPT Alt 2 in full.** The DA's point (d) is correct and
aligns with the user's stated priority (divergence suppression over shipping a
slice). The loop threads `inst.meta` through the record `assoc` re-mint
(`collection.zig:618` → `allocInstanceMeta`), covering `assoc` + `update` (update
rides assoc); the e2e asserts `(meta (assoc/update (with-meta r m) …))` → `m`. **D-313
is closed in this same commit, not opened.** Alt 3 (side table) is rejected on the
F-006 GC-rooting ground the DA gives. Alt 1's `declaresProtocol` discriminator is
NOT adopted: `kind == .defrecord` is the precise clj line (records always carry
meta; a deftype carries it only by *implementing* IObj, and an IObj-implementing
deftype already routes through the user `-with-meta` MethodEntry via
`dispatchOrNull` — so the native path for a non-record is unreachable-by-design and
the simpler `.defrecord` gate is exactly right, not a smallest-diff shortcut). The
`dissoc`-on-record case (demotes to a plain map in clj) is not a record re-mint and
is left to its existing path. This is a finished-form landing, not a sliced one.

## Consequences

- **Positive**: records join the metadata-bearing IObj family; **clojure.data.zip
  loads + functionally verifies** (added as a `verified_projects/` proof). The
  change is strictly less surgery than ADR-0110 (no membrane flip, no equality/
  hash arm, no registration) — the symbol precedent paid down the hard parts.
  Definition-derived (F-013): records get meta by being records, not per-lib.
- **Negative**: `with-meta` (and meta-preserving `assoc`) copies the field array
  (a fresh `gc.infra` alloc) — the irreducible cost of not sharing a finaliser-
  owned buffer. `dissoc` on a record (which clj demotes to a plain map) is left to
  its existing path, outside the record meta-threading.

## Affected files

- `src/runtime/type_descriptor.zig` — `TypedInstance.meta` field; `instMetaOf`;
  `instWithMeta` + `allocInstanceMeta` (pub; copies the field array);
  `allocInstance` nil-init; `traceTypedInstance` meta-mark line.
- `src/lang/primitive/metadata.zig` — kind-gated `.typed_instance` arms (split
  from the combined `.reified_instance` arm); `td_mod` import.
- `src/lang/primitive/collection.zig` — record `assoc` re-mint threads `inst.meta`
  via `allocInstanceMeta` (D-313 folded in, Alt 2).
- `test/e2e/phase14_typed_instance_metadata.sh` — record round-trip + deftype
  throw. `test/run_all.sh` wires it.
- `verified_projects/data.zip/` — the now-passing proof.
- `equal.zig` / `heap_tag.zig` / `runtime.zig` — **no change** (already
  field-structural / GcManaged / registered).
