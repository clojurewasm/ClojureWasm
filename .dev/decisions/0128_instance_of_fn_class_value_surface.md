# ADR-0128 — `instance?` is a fn over a class VALUE; complete the membership oracle

- Status: Proposed → Accepted (2026-06-10)
- Related: ADR-0109 (host-class-value resolution — the partial this completes),
  ADR-0116 (interface_membership SSOT), ADR-0059 / AD-003 (no-JVM simple class
  name), ADR-0102 / F-013 (host-interface closed-set), F-002 / F-011 (finished-form
  + commonization), D-373 (the driving debt), D-293 (the classDescriptor unify this
  folds in).
- Drives the discharge of D-373; folds in the classDescriptor-rename half of D-293.

## Context

`instance?` was a cljw MACRO (`expandInstanceQ`, macro_transforms.zig): it
auto-quoted the class symbol, `(instance? String x)` → `(__instance? (quote
String) x)`, so an unresolvable interface marker (`clojure.lang.IPersistentMap`)
worked as the literal class arg without the symbol needing to evaluate. But a
macro cannot be passed as a higher-order fn value, so `(condp instance? obj
Map$Entry …)` (flatland.ordered.map:59) evaluated `instance?` to nil →
"Cannot call value of type nil". In real Clojure `instance?` is a FN taking a
class VALUE (a class symbol evaluates to a Class). This blocked loading
flatland.ordered and any library using higher-order `instance?` (condp / map /
partial / apply — common). Confirmed red on a ReleaseSafe binary 2026-06-10:

- `(condp instance? "x" String :s :o)` → `Cannot call value of type 'nil'`
- `(map (partial instance? String) ["a" 1])` → same
- `(prn IPersistentVector)` → `Unable to resolve symbol: 'IPersistentVector'`
- `(instance? String "x")` → `true` (direct macro path worked)

The finished form (user-directed 2026-06-10, **NOT** a workaround): make
`instance?` a real fn. For that, every class symbol a library passes must
evaluate to a class VALUE — which means completing the class-symbol-as-value
surface ADR-0109 left partial (native / exception / opaque / Object / Number /
IFn landed; the `clojure.lang.*` interface markers — IPersistentMap / ISeq /
ILookup / Indexed / … — did NOT, so `(prn IPersistentVector)` was a NameError).

## Decision (Alt 2′ — complete the membership oracle, eliminate the special-cases)

Five parts:

1. **`instance?` becomes a fn.** `core.clj`: `(def instance? (fn* [c x]
   (rt/-instance-of? c x)))`; drop `expandInstanceQ` + its macro registration.
   A new primitive `-instance-of?` takes a class VALUE (`.type_descriptor`),
   extracts its `fqcn`, and returns `class_name.isInstance(x, fqcn)`. Because the
   class arg now evaluates, higher-order use (condp / map / partial / apply) works
   automatically — same as `clj`.

2. **Complete `class_name.isInstance` so it needs NO special-cases.** The macro's
   runtime half (`instanceQPrim`) special-cased opaque→false / Object→non-nil /
   Number→`number?` *before* calling `isInstance`. Those special-cases dissolve
   into the membership SSOT instead of being re-stated at the new primitive:
   - **opaque** (Integer / java.math.BigInteger): already returns false naturally
     — an opaque name is in no match table, so `isInstance` falls through to false
     (clj-faithful: a cljw int IS a Long, not an Integer).
   - **Number**: widen `interface_membership.NUMBER_TAGS` from `{integer, float}`
     to `{integer, float, big_int, ratio, big_decimal}` so it equals `number?`.
     (Verified safe: `number?` already uses that set; nothing extend-protocol-
     targets `Number`.)
   - **Object**: one line in `isInstance` — `if (isUniversalClass(simple)) return
     v.tag() != .nil;` (clj: every non-nil value is an Object; nil is not).
   `-instance-of?` is then JUST `isInstance(x, fqcn)` — no taxonomy branch. This is
   strictly cleaner than centralising the special-cases (the DA's Alt 2 `class_role`
   enum, below): the deepest F-011 reading removes the taxonomy rather than
   relocating it.

3. **One `class_name`-recognised analyzer arm** replaces the scattered
   Object / Number / IFn / opaque / exception / host_inert arms (analyzer.zig
   ~618-678). A single `classValueKeyFor(name)` helper returns the descriptor key
   for any recognised non-native class (exception / opaque / Object / interface
   marker / host_inert / stream), routing them all through ONE
   `classDescriptor(key)` call. `nativeTagFor → nativeDescriptor` (arm 1, keyed by
   tag for `(class x)` identity) and `rt.types.get` (registered Java surfaces)
   stay distinct descriptor sources, as before. The previously-missing interface
   markers now resolve as class values (so `(prn IPersistentVector)` and
   `(condp instance? x ISeq …)` work — definition-derived coverage per F-013, not
   a per-library add).

4. **`exceptionDescriptor` → `classDescriptor` (D-293 unify).** The function was
   already generic (mints a name-keyed `kind=.native` descriptor; "exception" was a
   historical misnomer used for opaque / Object / Number / IFn / host_inert too).
   Rename it + its `exception_descriptors` cache field across the ~16 call sites
   (runtime.zig / class_of.zig / analyzer.zig / dispatch.zig) so the name is honest
   (F-011 commonization). Pure rename, behaviour-preserving.

5. **`Map$Entry` resolves.** Add `java.util.Map$Entry` / `Map$Entry` → `MapEntry`
   to `class_name.FQCN_MAP`. `MapEntry` is already a `NATIVE_ENTRY` (tag
   `.map_entry`), so the symbol resolves to the native descriptor and
   `(instance? Map$Entry (first {:a 1}))` is true — clj's MapEntry implements
   java.util.Map$Entry.

`prefer-method` (the trivial sibling — a needless macro that was a pure
pass-through) was already converted to a fn in 869fa3db.

## Why Alt 2′ over the DA's Alt 2

The DA fork (verbatim below) recommended Alt 2: add a `class_role` enum field to
`TypeDescriptor`, computed once at mint, so `-instance-of?` / `classIsaPrim` /
the analyzer `switch` on role instead of re-deriving opaque/Object/Number from the
name string at three sites. The DA's F-011 diagnosis is correct — the
re-derivation IS a scatter. But its fix relocates the taxonomy onto the
descriptor; the cleaner fix **eliminates** it: once `isInstance` is a complete
membership oracle (part 2), `-instance-of?` has no taxonomy branch at all, so
there is nothing to centralise. A `class_role` enum would then be a second
classification axis to keep in sync with the name (the SSOT) — a new way to
introduce a bug, for no remaining caller. `classIsaPrim` keeps its
`isUniversalClass`/`isNumberClass`/`isIFnClass` reads, but that is the class-vs-class
`isa?` *hierarchy* question (legitimately distinct from value membership), and
those are shared predicate calls, not a duplicated taxonomy. Per F-002, the
choice is on finished-form cleanliness, not diff size; Alt 2′ is both cleaner and
smaller, so there is no cycle-budget tension to resolve.

## Consequences

- Higher-order `instance?` works (condp / map / partial / apply) — unblocks
  flatland.ordered and the 15+ data-structure libs that follow it.
- `(prn IPersistentVector)` etc. resolve as class values (definition-derived).
- `(instance? Number 1N)` is now true via the membership table (was true only via
  the special-case); `isInstance("Number")` == `number?` — one source.
- Unknown class in `instance?` now errors at ANALYSIS (`symbol_unresolved`) rather
  than the macro's runtime `class_name_unknown` — closer to clj's compile-time
  unresolved-class error. Existing e2e/corpus expectations updated to match.
- The classDescriptor rename touches ~16 sites; behaviour-preserving.

## Verification (F-011 clj-oracle; D-177 anti-false-discharge)

- Re-run ALL `instance?` corpus/e2e (instance_interfaces / instance_iterable /
  isa_class_hierarchy / exception_class / class_as_value / opaque_host_class)
  against the `clj` oracle.
- Add a clj-diff corpus line for higher-order `instance?`
  (`(condp instance? obj …)`, `(map (partial instance? String) xs)`,
  `(filter (partial instance? Number) xs)`) per clj_diff_sweep.md Discipline 1 —
  the discharge text must not claim higher-order works without a corpus probe.
- `(class x)` / AD-003 simple-name unchanged; `(extend-type Opaque P …)` stays a
  load-only no-op.
- Verify the FULL flatland.ordered.map chain past Map$Entry (further blockers may
  follow — they are separate units).

## Alternatives considered (Devil's-advocate, fresh context — verbatim)

> Active F-NNN: F-002 (finished-form > diff), F-011 (commonization + clj
> equivalence), F-013 (definition-derived, no per-lib allowlist), ADR-0059/AD-003
> (no-JVM simple name), F-005 (numeric collapse). LOC/diff size is NOT a constraint.

> # Devil's-advocate review — D-373 (instance? macro → fn)
>
> A structural fact dominates the analysis: **`class_name.isInstance(v, name)`
> already does the entire membership decision from the name string** — Throwable
> hierarchy, native-exact, interface, user-type. The opaque/Object/Number
> special-cases in `instanceQPrim` are *also* keyed off the name string via
> `host_class.isKnownOpaqueClass` / `isUniversalClass` / `isNumberClass`. So the
> runtime already has a single name-keyed membership oracle; the analyzer's 8-arm
> cascade is a *second*, parallel name-keyed oracle that re-derives "which
> descriptor does this name get". The duplication Alt B consolidates is real and
> is an F-011 violation in the current code.
>
> ## Alternative 1 — smallest-diff
> Keep `expandInstanceQ` as the macro for the direct-call case, but additionally
> `(def instance? (fn* [c x] (rt/-instance-of? c x)))` as a fallback Var; add a
> class-value arm for *only* the interface markers flatland touches + Map$Entry.
> **(a) Better:** smaller blast radius; the proven direct-call path untouched.
> **(b) Breaks/risks:** a **macro-and-fn-with-the-same-name** shape — in clj
> `instance?` is *only* a fn. Two code paths (macro auto-quotes; fn evaluates) can
> diverge the instant a user writes `(let [c String] (instance? c x))`. This is
> the Smallest-diff-bias smell + a NEW duplication. The "only the markers flatland
> touches" arm is an **F-013 violation outright** — the library-by-library
> allowlist F-013 prohibits. **(c) F-NNN: violates F-011 and F-013. Rejected on
> invariant grounds, not diff size.**
>
> ## Alternative 2 — finished-form-clean (the `class_role` field)
> Alt B (drop the macro, fn over a class value, one `canonicalClassValueName` SSOT,
> rename exceptionDescriptor→classDescriptor, consult ns.imports, add Map$Entry)
> PLUS a `class_role` enum on TypeDescriptor. The same category taxonomy
> (opaque/universal/number/ifn/native/interface/host_inert/user) is re-derived from
> the name string at THREE sites: `instanceQPrim` (core.zig:77-84), `classIsaPrim`
> (core.zig:109-113), analyzer (analyzer.zig:630-658) — each with its own ordering
> and bug surface. The clean form: give `TypeDescriptor` a `class_role` field set
> ONCE at mint from the single `canonicalClassValueName` SSOT; `-instance-of?`
> becomes `switch (td.class_role)` → opaque⇒false / universal⇒non-nil /
> number⇒numeric? / else⇒`isInstance(x, fqcn)`; no name re-matching. `TypeKind`
> (type_descriptor.zig:33) already exists but is about *origin* (native/deftype/
> reify), not *class-membership role* — `class_role` is orthogonal and additive.
> **(a) Better than Alt B:** Alt B consolidates the analyzer's 8 arms but leaves
> `instanceQPrim`/`classIsaPrim` still re-deriving opaque/Object/Number from the
> name — the half-swept-area smell (clj_diff_sweep.md Discipline 2). Alt 2 closes
> all three: the name reverts to identity/label, the role is computed once and
> consumed by an exhaustive `switch` (compiler-checked). **(b) Risks:** larger diff
> (every mint site sets the field); a wrong role at a mint site → wrong instance?
> (mitigated by exhaustive switch + clj-diff corpus). **(c) F-NNN:** fully
> compliant; the strongest F-011 reading. **Verdict on name-vs-scatter:** the name
> is a legitimate SSOT *for identity* (`(= (class x) Long)` must compare names) but
> an illegitimate scatter *for role decisions*. Alt 2 splits the two: name =
> identity, class_role = decision.
>
> ## Alternative 3 — wildcard (membership predicate fn-pointer per descriptor)
> Each class-value descriptor carries `membership: *const fn(Value) bool`;
> `-instance-of?` is `return td.membership(x)`; name-string matching disappears from
> the hot path. **(a) Better:** maximal devirtualization (a latent PERF win); the
> closest cljw analogue to a JVM Class's `isInstance`. **(b) Breaks/risks:** fn
> pointers in the descriptor literal are exactly the cost type_descriptor.zig:54-66
> documents — `method_table`'s `Value.initBuiltinFn(&fn)` "is not comptime on Mac,
> forcing an init-time alloc + deinit free"; a `membership` fn pointer drags every
> `classDescriptor` out of the comptime-const path the named-descriptor cache
> enjoys. It also **scatters** the membership logic into N closures — the inverse of
> F-011. Adjacent to the `pub var` vtable prohibition (ROADMAP §13). **(c) F-NNN:**
> compliant in letter but weaker on F-011 than Alt 2 (N closures vs one switch) and
> fights the settled comptime-const descriptor discipline.
>
> ## RECOMMENDATION: Alternative 2 (the `class_role` field).
> Alt B is correct + clean for the analyzer but incomplete — it commonizes the 8
> arms while leaving the identical taxonomy re-derived at `instanceQPrim` and
> `classIsaPrim` (the half-swept-area pattern). F-011 points past Alt B to Alt 2:
> compute `class_role` once, consume by exhaustive switch. Per F-002 the larger
> diff is NOT a reason to prefer Alt B — that downgrade would be the Cycle-budget-
> defer smell. Alt 1 rejected on F-011 + F-013; Alt 3 weaker-than-Alt-2 on F-011.
> **Caveat for the ADR regardless of choice:** add a clj-diff corpus line for
> higher-order `instance?` per clj_diff_sweep.md Discipline 1 — the discharge text
> must not claim higher-order works without a corpus probe (the D-177 lesson).

### Main-loop disposition of the DA recommendation

The main loop adopts **Alt 2′** — Alt 2's analyzer-arm consolidation + ns/SSOT
unification + rename, but it **completes the `isInstance` membership oracle so the
taxonomy is eliminated, not relocated onto a `class_role` enum**. The DA's
half-swept-area diagnosis of Alt B is the reason Alt 2′ exists; Alt 2′ honours it
more completely than the DA's own Alt 2 (zero remaining taxonomy branch in
`-instance-of?` vs a `switch` on a second axis). `classIsaPrim` keeps its
predicate reads (the `isa?` hierarchy is a distinct question). The DA's caveat
(higher-order corpus line) is adopted verbatim in § Verification.
