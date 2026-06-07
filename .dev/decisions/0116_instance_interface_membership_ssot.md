# ADR-0116 — `instance?` clojure.lang interface membership SSOT + deref family

- **Status**: Proposed → Accepted
- **Date**: 2026-06-08
- **Discharges**: **D-308** (`(instance? clojure.lang.IDeref x)` + the deref /
  pending / ref interface family raised `class_name_unknown`). Partially
  addresses **D-317** (the `class_name.matchInterface` ↔ `NATIVE_EXTEND_TARGETS`
  duplication) — see Decision C for the part deferred and why.
- **Cross-refs**: ADR-0109 (`instance?`/`isa?` class surface), ADR-0114 /
  ADR-0102 (`host_interface` / `host_interfaces.yaml` — the deftype-supertype
  marker concern, DISTINCT from this membership concern), ADR-0059 / AD-003
  (no-JVM class), F-002 / F-011 / F-013 / F-009; `zig_tips.md` (the
  exhaustive-`Value.Tag`-switch guidance that shaped the table representation);
  `provisional_marker.md` (permanent-no-op ban). Debt: D-271 (the `range`/
  `chunked_cons` no-meta-slot gap that gates IObj/IMeta), D-317 (extend-target
  reconciliation residual).

## Context

`(instance? clojure.lang.IDeref x)` raised `name_error: class
'clojure.lang.IDeref' is not a known class name`. core.memoize:67 needs it
(its `RetryingDelay` deftype implements IDeref + IPending). A 2026-06-07 naive
fix (`expandInstanceQ`: rewrite `(instance? marker x)` → `(satisfies? proto x)`)
was REVERTED — it broke `(instance? clojure.lang.IFn :kw)` → clj `true`: a
keyword IS natively an IFn (callable-as-lookup) but does NOT extend an IFn
*protocol*, so satisfies? is false. **Lesson: instance?-on-host-interface =
native tag membership ∪ user-deftype protocol satisfaction — never a satisfies?
substitution.**

`class_name.zig` already holds a definition-derived tag-set membership table for
~22 interfaces (the `matchInterface` switch-arm chain, clj-oracle-grounded). The
gap is (a) the deref/pending/ref family is absent from all three of its
hand-maintained structures (`FQCN_MAP`, the `isInterfaceName` 24-deep `or`-chain,
`matchInterface`), so the name is unrecognised; (b) `matchUserType` matches a
user type only by ancestor-`fqcn` name-equality, never by protocol satisfaction,
so a deftype that *extends* IDeref is not an IDeref instance.

## Decision A — one in-code SSOT for native interface membership

New `src/runtime/interface_membership.zig`: a single comptime table
`Entry{ name: []const u8, tags: []const Value.Tag }[]` mapping each recognised
clojure.lang interface to the native `Value.Tag` set that implements it.
Co-membership interfaces (IPersistentCollection/Seqable, Associative/ILookup,
Indexed/IPersistentVector, …) point at **shared tag-set constants** so a set is
authored ONCE (the DRY trap the DA flagged in R2). `class_name.zig` derives ALL
THREE of its consumers from this one table — `matchInterface` (membership),
`isInterfaceName`/`isKnown` (the recognised-name set, **retiring the `or`-chain**
— F-013 structural close), so the three can no longer drift.

**Representation = forward `{name, tags}` table, NOT an inverse exhaustive
`switch (Value.Tag)`.** The DA's finished-form-clean Alt-2 proposed the inverse
switch for compile-time tag-exhaustiveness, but `zig_tips.md` explicitly rules
that wide value-dispatch enums (`Value.Tag`, heading 54→64 slots per F-004) use
`else =>`, NOT exhaustive enumeration ("a new tag is *meant* to fall into the
default until its primitives are wired in"). The forward table honours that idiom
and is a single source (no yaml-vs-code split → no drift gate needed; the
existing instance? membership was itself UN-gated, and a single in-code SSOT is
the structural close, not a second SSOT-of-record + gate).

The deref/pending/ref family added (oracle-verified vs `clj`, see corpus
`test/diff/clj_corpus/instance_interfaces.txt`):

| interface      | native tags                                                          |
|----------------|----------------------------------------------------------------------|
| IDeref         | atom, agent, ref, volatile, future, promise, reduced, delay, var_ref |
| IRef           | atom, agent, ref, var_ref                                            |
| IReference     | atom, agent, ref, var_ref, ns                                        |
| IPending       | delay, future, promise, lazy_seq                                     |
| IBlockingDeref | future, promise                                                      |

## Decision B — user-deftype protocol-satisfaction ∪ arm (name-based, in `matchUserType`)

`matchUserType` (class_name.zig) gains a second pass: after the ancestor-`fqcn`
walk, it scans each descriptor's `method_table[].protocol_name` and
`protocol_impls[]` for the normalised interface name. A deftype declaring
`clojure.lang.IDeref` registers its method under cljw protocol name `"IDeref"`
(the `host_interface` remap target = the bare canonical), and the FQCN_MAP
normalises `clojure.lang.IDeref` → `"IDeref"`, so the names meet.

**This is name-based and lives in the `runtime/` leaf (no `rt`), deliberately
NOT the DA's R3 shape** (resolve the bare name → a protocol Var → `Var.deref()`
→ `protocol.satisfies`). The DA's own R3 finding is the reason: a user
protocol's `fqcn()` is namespace-QUALIFIED (`<ns>/<name>`) while the deftype's
stored `protocol_name` for a host-remapped interface is the BARE canonical, so a
Var-resolution path risks a bare-vs-qualified mismatch (and a silent never-match
= permanent-no-op, forbidden). Matching the stored `protocol_name` string
directly — the same field `protocol.satisfies` itself compares — is both simpler
and exactly correct for the host-marker remap case. Native membership is PRIMARY,
this arm is ADDITIVE: the two are OR-unioned, never substituted (so keyword∈IFn
survives).

## Decision C — partial D-317 derivation (the safe 3/4), IPersistentVector deferred

`host_interface.nativeExtendTags` (the extend-protocol-TARGET native-tag
distribution, macro_transforms.zig:2405) is derived from the new SSOT for the
interfaces where the two consumers AGREE: **ISeq, Named, IPersistentMap** (the
7-tag ISeq list etc. now lives in ONE place). **IPersistentVector is NOT
unified**: instance? membership = {vector, map_entry} (a MapEntry IS an
IPersistentVector in clj), but extend-target distribution = {vector} only.
Deriving extend-target from the membership set would start distributing
IPersistentVector-extended protocols to `map_entry` — arguably MORE clj-correct,
but a behaviour change requiring verification that `map_entry` carries an
extendable native descriptor (and oracle confirmation). That is a genuine design
question, not a mechanical refactor — deferred to D-317 (kept open) per F-003
(decision-deferral over decision-seizure on a structural reconciliation), NOT
cycle-budget (the divergence is real, not a size dodge).

## Decision D — IObj / IMeta enumerated but NOT activated (D-271 coordination)

The oracle shows IObj / IMeta membership is large and intricate (IObj =
promise/future + most collections/seqs + fn + symbol, EXCLUDING
map_entry/keyword/delay; IMeta = IObj ∪ atom/agent/ref/var/ns). Activating them
now would break F-011 behavioural equivalence: clj guarantees `(instance? IObj
x)` ⟹ `(with-meta x m)` succeeds, but cljw's `.range`/`.chunked_cons` substrate
has **no meta slot** (D-271), so `(instance? IObj (range))`→true while
`(with-meta (range) m)`→cljw error. Per `accepted_divergences.md`, an AD must
cite a project INVARIANT; "D-271 hasn't landed" is a temporal incomplete-impl
state, not an invariant — so an AD would launder an unfinished feature (itself a
smell, per the DA's R1). Therefore: the full IObj/IMeta tag sets are
**enumerated in an inactive comment block** in interface_membership.zig (cheap;
prevents re-discovery, F-013 clause 4 "網羅 the recognition table up-front, wire
impl incrementally"), their MEMBERSHIP ACTIVATION gated on D-271, and D-271's row
records IObj/IMeta membership as one of its deliverables. Until then
`(instance? clojure.lang.IObj x)` stays a loud `class_name_unknown` (an explicit
transient signal, not a silent lie).

## Alternatives considered (Devil's-advocate subagent, fresh context, verbatim)

> ### Alternative 1 — Smallest-diff: extend the existing three tables in place, no new SSOT
> Add the deref/pending/ref family directly to `class_name.zig`'s three existing
> structures (`FQCN_MAP`, `isInterfaceName`'s `or`-chain, `matchInterface`'s
> `switch`-arm chain), plus the ∪ arm. Leave `NATIVE_EXTEND_TARGETS` untouched —
> D-317 stays open.
> - **Better:** Zero migration risk (the Long/BigInt origin special-case in
>   `matchNativeExact` is never disturbed); keeps the per-interface provenance
>   comments. Smaller blast radius.
> - **Breaks/costs:** Defeats D-317; `isInterfaceName` stays the 24-deep
>   `or`-chain the survey identifies as "the exact 個別最適化 shape F-013 clause 3
>   warns about". Under F-013 + F-002 this is the Smallest-diff-bias /
>   Cycle-budget-defer smell — cheaper, reaches a dirtier finished form.
>   Recommend against unless an F-NNN blocks B (none found).
>
> ### Alternative 2 — Finished-form-clean: single SSOT as an INVERSE exhaustive `switch (Value.Tag)`, fold D-317 + `isKnown` in
> Represent the SSOT as a comptime exhaustive `switch (Value.Tag)` returning each
> tag's interface set; both consumers + `isKnown`/`isInterfaceName` derive.
> - **Better:** A new `Value.Tag` breaks the build until classified
>   (compile-time structural close, no gate script); subsumes the `or`-chain.
> - **Breaks/costs:** Larger diff; provenance comments must be re-homed; inverse
>   reads less naturally for "what implements IDeref?". *[Main-loop note: this
>   Alt is DECLINED because `zig_tips.md` rules wide `Value.Tag` switches use
>   `else =>`, not exhaustive enumeration — the inverse switch fights the project
>   idiom. Decision A takes the forward table, which is the F-013 structural close
>   compatible with that idiom.]*
>
> ### Alternative 3 — Wildcard: drive native membership from the defprotocol/extend-protocol registry
> For interfaces that ARE cljw defprotocols, read membership from the protocol
> registry instead of a static set.
> - **Better:** Maximally DRY; one source for instance?/satisfies?/distribution.
> - **Breaks/costs:** RE-INTRODUCES the reverted bug — `(instance? IFn :kw)` must
>   be true (keyword is *natively* IFn, not extend-protocol-registered), so a
>   registry read under-reports every native-but-not-extended tag; plus a
>   load-order hazard + a `runtime/`-leaf-imports-registry zone breach. Fails
>   F-011 on the IFn family. Salvage = registry feeds ONLY the additive ∪ arm
>   (which Decision B does, name-based).
>
> ### R1 — scope boundary (deref now, IObj/IMeta deferred): LEADING F-NNN finding
> The maximally-網羅 move adds IObj/IMeta in the same big-bang (Discipline 2).
> BUT the D-271 entanglement is REAL: clj's IObj ⟹ withMeta, cljw's range/cons
> have no meta slot, so claiming IObj membership breaks F-011 — and an AD to
> cover it would cite "D-271 unlanded" which is NOT an invariant (the AD rule
> forbids this), so it belongs in a debt row, not the AD ledger. Recommendation:
> defer ACTIVATION, but ENUMERATE the IObj/IMeta/IReference tag rows now (cheap,
> prevents re-discovery) with membership gated on D-271; classify IDeref's JVM
> super-interfaces (Supplier/Runnable/Callable/Comparable) as no-JVM uniformly-
> false in the same cycle. *[Main-loop disposition: adopted — Decision D
> enumerates inactive + gates on D-271. The JVM super-interfaces are left to a
> follow-up note (a separate java.* functional-interface family, not the
> clojure.lang deref family — out of this cycle's definition-derived class).]*
>
> ### R2 — SSOT migration risk: SAFE
> Read every `matchInterface` arm (L305-426): all 24 are pure tag-set membership;
> the Long/BigInt `origin`-flag special case is in `matchNativeExact` (L276-280),
> NOT `matchInterface` — a flat `{name, tags}` table reproduces it exactly. ONE
> trap: co-membership interfaces share a tag set (IPersistentCollection/Seqable,
> Associative/ILookup, Indexed/IPersistentVector) — the SSOT must alias them to a
> shared set or it re-introduces the very drift D-317 kills. `Number` has TWO
> definitions (core.zig `isNumberClass` = the live broad path incl.
> big_int/ratio/big_decimal; class_name L317 = narrow integer/float, dead for the
> primitive path) — either unify or document core.zig owns Number. No PERF marker
> needed (instance? is a predicate, not a hot inner loop).
>
> ### R3 — ∪ arm placement + precedence
> "Native PRIMARY, protocol ADDITIVE" = OR-union, never substitution (correct).
> CRITICAL HOLE: a user protocol's `fqcn()` is namespace-QUALIFIED
> (`<ns>/<name>`), not bare `"IDeref"`, so the ∪ arm cannot compare the bare
> instance? symbol to `proto.fqcn()` — it must resolve the name → protocol Var →
> `Var.deref()` → `protocol.satisfies`, OR match the stored `protocol_name`
> directly. Non-protocol interfaces (Number/Iterable) must no-op cleanly (not
> error). `instanceQPrim` has `rt`+`env` (env.zig:173 resolve / :110 deref);
> `class_name.isInstance` does not. *[Main-loop disposition: Decision B matches
> the stored `protocol_name` string directly in `matchUserType` — the bare
> canonical the host-remap deftype actually stored — which sidesteps the
> qualified-fqcn mismatch the DA flagged and needs no `rt`. Verified empirically
> during green.]*
>
> ### R4 — gate / framework-completion
> `class_name.zig` membership is currently UN-gated (no script syncs FQCN_MAP /
> isInterfaceName / matchInterface). A new SSOT without a gate is the half-built-
> framework smell; recommend folding membership into `host_interfaces.yaml`
> (`native_implementors:` field) so the existing G4 gate extends, AND retire the
> `isInterfaceName` `or`-chain in the same cycle. *[Main-loop disposition: the
> `or`-chain IS retired (Decision A). The yaml-fold is DECLINED: native-tag
> membership is a DISTINCT concern from host_interfaces.yaml's deftype-supertype
> markers (one-SSOT-per-concern, ADR-0102's own principle); and a single in-code
> table that ALL consumers derive from has no record-vs-code split to gate (drift
> is structurally impossible). The corpus regression
> (`check_corpus_regression.sh`) + unit tests are the behavioural lock.]*

## Consequences

- `(instance? clojure.lang.IDeref/IRef/IReference/IPending/IBlockingDeref x)`
  resolves for native values and user deftypes (∪ arm); core.memoize's IDeref/
  IPending needs are met. The IFn-keyword regression guard is locked.
- `class_name.zig`'s instance? membership is one derived-from-SSOT concern; the
  `isInterfaceName` `or`-chain is gone.
- D-317 narrows (ISeq/Named/IPersistentMap unified) but stays open for the
  IPersistentVector extend-target reconciliation.
- D-271 gains IObj/IMeta membership as a coordinated deliverable.
- New `Value.Tag`s still fall to `else` (no instance? membership) until
  classified — consistent with zig_tips; a future tag's interface membership is
  added to the SSOT rows as it is wired.

## Affected files

- NEW `src/runtime/interface_membership.zig` (SSOT + tests)
- `src/runtime/class_name.zig` (matchInterface / isInterfaceName / isKnown
  derive; FQCN_MAP deref-family rows; matchUserType ∪ arm)
- `src/runtime/host_interface.zig` (nativeExtendTags derives ISeq/Named/
  IPersistentMap from the SSOT; IPersistentVector kept explicit)
- `src/main.zig` (test aggregator `_ = @import` of the new file)
- `test/e2e/phase14_instance_deref_family.sh` + `test/run_all.sh` registration
- `test/diff/clj_corpus/instance_interfaces.txt` (deref-family corpus rows)
- `.dev/debt.yaml` (D-308 discharged; D-317 narrowed; D-271 IObj/IMeta note)
