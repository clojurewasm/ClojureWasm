# 0109 — Unified host-class-VALUE resolver (`classDescriptor` + `kind`)

- **Status**: Accepted
- **Date**: 2026-06-07
- **Phase**: Phase 14 — Convergence Campaign Stage 1.3 (library ladder)
- **Amends**: ADR-0059 (class values), generalises `exceptionDescriptor`
- **Discharges**: D-293 (host-class-value facet)
- **Tags**: phase-14, interop, host-class, analyzer, isa, F-013

## Context

The ladder repeatedly hits a host CLASS used as a VALUE that cljw fails to
resolve (`Unable to resolve symbol: 'Object'`): `(derive Object root-type)`
(algo.generic), `clojure.lang.IFn` (core.contracts), `java.lang.AssertionError`
(tools.trace), `Integer`/`java.math.BigInteger` (numeric-tower :98/:127). cljw
already RECOGNISES these names in other roles — host_class.zig (Throwable
ENTRIES, for `(catch E e)`), host_interfaces.yaml (deftype/reify supertype
markers), NATIVE_ENTRIES (real cljw types), and the F-005 collapsed-numeric set
— but NOT as resolvable symbol VALUES in `analyzeSymbol`.

A reverted probe (D-293) showed resolving the collapsed-numerics as OPAQUE
distinct class values makes `(= (type 5) Integer)`/`(instance? Integer 5)`
clj-faithful (false), but is COUPLED to extend-type: `(extend-type Integer P …)`
then CRASHED (`__extend-type!` `@constCast`s the descriptor and mutates its const
`&.{}` method_table).

## Decision

A single resolver `classDescriptor(name) → {descriptor, kind}` (generalising
`rt.exceptionDescriptor`), resolving in precedence order
NATIVE_ENTRIES → OPAQUE (F-005 collapsed-numerics) / INERT (recognised-but-
unmodelled host) → throwable (host_class) → marker (host_interface) →
`name_error`, tagged `kind ∈ {:native, :opaque, :inert, :throwable, :marker}`.
`analyzeSymbol` resolves a recognised host-class name to its descriptor VALUE.
Consumers branch on `kind`:

- **instance? / =**: `:opaque`/`:inert` → no cljw value has the type → false.
- **extend-type / protocol-registration**: `:opaque`/`:inert`/`:throwable`/
  `:marker` (non-deftype descriptors) → **load-only no-op**, NOT a crash. This is
  F-011-FAITHFUL, not a forbidden permanent-no-op: clj also never dispatches an
  extension on a never-instantiated class, so cljw's no-op is behaviourally
  identical (a corpus line pins that clj never dispatches). The `OPAQUE ∩ NATIVE
  = {}` comptime assertion keeps the must-implement (`:native`, e.g. Long) case
  from ever being confused with the faithful-no-op (`:opaque`) case.
- **isa?**: a `:throwable` descriptor answers via its existing host_class PARENT
  links (`(isa? AssertionError Throwable)` → true, faithfully). `Object` is wired
  as the UNIVERSAL ROOT: `(isa? <any-class> Object)` → true (one special case,
  NOT a fabricated general hierarchy — needed because algo.generic's `(derive
  Object root-type)` is only HALF-unblocked by Object-as-value; its INTENT
  requires Object answer as every type's supertype). Only the collapsed-numeric
  hierarchy gap (`(isa? Integer Number)` — cljw has no Number node) is an AD; the
  `isa?` AD is NARROW, not blanket (a blanket AD would over-diverge, discarding
  the Throwable structure cljw already owns).

Scope = ONE definition-derived unit (the union of the three closed sets), NOT
staged — a half-swept resolver whose `kind` is non-total for some recognised
names is worse than none (consumers can't assume totality; numeric-tower would
stay red while the ledger reads "host-class values resolve").

Full JVM class hierarchy (making `(isa? Integer Number)` true) would require
amending ADR-0059 / adding collapsed-numeric-tower nodes — user-owned; excluded
from this envelope (the narrow AD records the gap).

## Alternatives considered

_Devil's-advocate subagent output (fresh context), verbatim:_

> **Alt 1 — Smallest-diff: keep three recognizers, analyzeSymbol tries each in
> turn (NO unification).** Better: minimal new surface; reuses three already-gated
> SSOTs without a fourth tag space; F-013-derivation trivially preserved. Breaks:
> does NOT cover the collapsed-numeric case (Integer/java.math.BigInteger) — none
> of the three recognizers own those names, so numeric-tower stays red; to fix you
> add a fourth recognizer anyway, and now four recognizers each mint descriptors
> with ad-hoc instance?/=/extend-type semantics, with `kind` re-derived at every
> call site by "which table answered" — the incidental complexity the `kind` field
> deletes. Smallest-diff bias: looks smaller, relocates the kind-dispatch into N
> call sites.
>
> **Alt 2 — Finished-form: ONE classDescriptor(name)→{descriptor,kind} (the D-293
> design-of-record).** Better: `kind` is the single place "what can this
> class-value do" is answered; instance?/=/extend-type/future cast/bases read one
> tag instead of asking which table minted it; the recognizers' role-overlap
> (Object in host_class AND host_interface) resolves into one precedence. F-013
> honoured: the resolver's input sets ARE the three closed SSOTs unioned by fixed
> precedence. Breaks: the precedence order becomes load-bearing and must be tested
> (Object is throwable-rooted AND a marker — order says throwable wins; both map to
> load-only no-op so observable behaviour coincides today, but needs a test, not
> just the comptime intersection check).
>
> **Alt 3 — Wildcard: one interned HostClass with a capability BITSET
> (INSTANTIABLE/CATCHABLE/EXTENDABLE_AS_NOOP/IN_HIERARCHY), no categorical kind.**
> Better: directly answers the isa? question — cljw HAS Throwable parent links, so
> `(isa? AssertionError Throwable)` is faithfully answerable TODAY; a blanket isa?
> AD is an OVER-divergence discarding real structure. The IN_HIERARCHY bit lets
> isa? answer what cljw models and AD only what it cannot (`(isa? Integer Number)`
> — no Number node). Bitset is also honest about Object (catchable + extendable +
> hierarchy-root simultaneously; a single enum forces a lossy choice). Breaks: more
> machinery than the ladder demands; 2^4 capability matrix mostly unused →
> dead-bit / Reservation-as-bias risk; widens scope beyond the four blockers.
>
> **Recommendation (per F-002): Alt 2 (single classDescriptor + kind) with Alt 3's
> narrowed-isa? insight absorbed — NOT a blanket AD.** Alt 2 is the finished form
> (the collapsed-numeric set has no existing recognizer, so a fourth source is
> needed regardless; once four sources mint class-values the consumers MUST
> distinguish no-cljw-value / matchable / load-only — intrinsic to the problem;
> encode it as a `kind` field where the data is, not as "which recognizer
> answered"). Alt 1's smaller diff merely relocates kind-dispatch (Smallest-diff
> bias). Alt 3's bitset is premature, but its isa? insight (`:throwable`
> descriptors answer isa? via existing parent links) must be absorbed; blanket AD
> rejected.
>
> **Assessment 2 — `(derive Object x)` only HALF-unblocks algo.generic.** Resolving
> Object to a descriptor VALUE lets `derive` receive its arg without a resolve
> error, but algo.generic's `root-type` pattern then expects `(isa? <any> Object)`
> → true (Object as universal root). Object-as-value unblocks derive's STORAGE but
> NOT its INTENT unless isa? special-cases Object as universal supertype. FLAG: a
> real second requirement on the critical path — the ADR must wire `(isa? <any>
> Object)`→true (one-line universal-root special case) or algo.generic stays
> half-blocked. isa? host semantics are not optional dressing.
>
> **Assessment 3 — extend-type-on-host no-op is FAITHFUL, not a forbidden lie.**
> provisional_marker.md forbids a permanent no-op that pretends to implement
> observable-as-missing behaviour. `(extend-type Integer P …)` extends a class for
> which NO cljw value can exist (F-005); in clj the same extension on a
> never-instantiated class is ALSO dead (no instance → no dispatch). cljw's no-op
> is behaviourally identical → F-011-faithful, passes no-op-forbidden. The
> forbidden case would be no-op'ing `(extend-type Long P …)` (Long HAS values); the
> OPAQUE ∩ NATIVE = {} assertion keeps those apart. Pin with a corpus line showing
> clj also never dispatches (Discipline 1).
>
> **Assessment 4 — blanket isa? AD is an over-divergence.** Throwable parent links
> make `(isa? AssertionError Throwable)` faithfully answerable; ADR-0059's
> no-JVM-hierarchy only truly bites the numeric tower (Integer/Number, no nodes).
> Finished form: isa? answers what host_class parent links model, ADs ONLY the
> collapsed-numeric hierarchy gap.
>
> **Assessment 5 — one definition-derived unit, NOT staged.** The recognised-host-
> class surface is DEFINED by host_class ENTRIES ∪ host_interfaces.yaml ∪ F-005
> collapsed set — closed and known now. Staging (exceptions→markers→numerics)
> leaves the resolver answering some names and erroring on others for cycles — a
> half-swept surface whose ledger reads "host-class values resolve" while
> numeric-tower stays red (Micro-coverage-grind / half-swept-area smell). Drive all
> three sets through classDescriptor in one push, land the corpus, close it.
>
> No alternative requires violating an F-NNN. The Object-universal-root isa? wiring
> does NOT violate ADR-0059 (one special-case answer, not a fabricated general
> hierarchy). Full JVM hierarchy (`(isa? Integer Number)`→true) is user-owned
> (amend ADR-0059) — excluded; the narrow AD records the numeric-tower isa? gap.

## Consequences

- Bare/dotted recognised host-class names resolve as class VALUES; `(derive
  Object …)` + Object-root isa? unblock algo.generic; `Integer`/`BigInteger`
  value-compares land numeric-tower's :98/:127 (it then chains to deeper
  java.math interop — D-302 stays parked on the BigDecimal surface).
- `extend-type` on a host class is a faithful load-only no-op (corpus-pinned).
- A new AD records ONLY the collapsed-numeric `isa?`-hierarchy gap.
- `exceptionDescriptor` → `classDescriptor` rename ripples to its call sites;
  `classPrim`/`Util/classOf` (via `class_of.zig`) are unaffected (they take a
  value, not a name).
