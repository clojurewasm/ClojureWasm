# ADR-0102 — Host-interface recognition is a closed-set SSOT (`host_interfaces.yaml`) + a mechanical gate, not a hand-grown allowlist

- **Status**: Proposed → Accepted (2026-06-07)
- **Driven by**: F-013 (just declared) clause 3 — the "個別最適化 entry" must be
  closed *structurally*. D-275 slice 1 landed `Object/toString` recognition by
  hand-coding `std.mem.eql(name, "Object")` at ~5 sites; slices 3+
  (`clojure.lang.*`) would multiply that scatter library-by-library. The user
  asked for the entry to be structurally prevented, not watched.
- **Relates to**: F-013 (definition-derived comprehensive coverage), F-009
  (impl neutrality + `compat_tiers.yaml` as the cross-reference index + G1/G2/G3
  gate precedent), F-002 (finished-form wins), F-011 (behavioural equivalence vs
  `clj`), ADR-0059 / AD-003 (no-JVM — `Object`/`clojure.lang.*` are NOT real host
  classes), ADR-0066 (deftype macro), ADR-0008 (protocol dispatch), D-275
  (the Object slice this generalises), D-276 (`extend-type Object` as-target).

## Context

In `clj`, `deftype`/`reify`/`extend-type` may name host supertypes/interfaces in
the impl-spec position — `Object` (for `toString`/`equals`/`hashCode`) and the
`clojure.lang.*` family (`Seqable`, `ISeq`, `ILookup`, `IDeref`, `Counted`,
`IFn`, `IObj`, `IPersistentMap`, …) that collection libraries implement. cljw has
**no JVM Class** (ADR-0059); these are not cljw protocol Vars and not real
classes — they are **marker names that select a dispatch family** (`Object/toString`
→ the str/print consult; `clojure.lang.Seqable` → cljw's existing `-seq`
protocol).

D-275 slice 1 made `Object` recognised by hand-coding `std.mem.eql(name,
"Object")` at 5 sites (`macro_transforms.zig` `isHostMarker` + 2 quote-wrap call
sites; `protocol.zig` `hostMarkerCanonicalName` + 2 `eql`/guard sites). This is
the **un-structured recognition entry**: when a real library (the convergence
campaign's gap-discovery technique, F-013 clause 1) hits a new `clojure.lang.*`
interface, the loop is tempted to add `or eql("IDeref")…` at each site — the
recognised set grows **library-by-library** (the ad-hoc "make this lib pass" that
F-013 clause 2 forbids).

`compat_tiers.yaml` already structurally defends the **Java class** surface (Tier
A/B/C/D + cw-native alternative + G1/G2/G3 gates) so a library hitting a Java
class triggers a *tier lookup*, never a per-library special-case. The
deftype/reify host-interface surface has no equivalent SSOT — only the scatter.

## Decision

Apply `compat_tiers.yaml`'s proven closed-set + tier-gate pattern to the
host-interface surface, as a **dedicated SSOT** with a **materialized closed
set** (not re-derived from a mutable clone) + a **two-clause gate**.

1. **SSOT — `host_interfaces.yaml`** (a new top-level file, sibling to
   `compat_tiers.yaml` / `placement.yaml` / `accepted_divergences.yaml`; NOT a
   `host_classes` extension — see Alternatives/DA). Each row:
   ```yaml
   - name: Object                 # the bare marker name
     aliases: [java.lang.Object]   # qualified spellings clj source may write
     routes_to: object-method-family   # protocol name | method-family | feature_not_supported
     methods:                      # per-method wiring status (so a partial family is honest)
       toString: { wires_to: "str/print consult", status: wired }
       equals:   { status: feature_not_supported }
       hashCode: { status: feature_not_supported }
     derives_from: "java.lang.Object — clj universal supertype; Clojure 1.12 deftype/reify legal supertype"
     tier: A
   ```
   The **rows ARE the closed set.** Each carries a `derives_from:` note citing the
   Clojure interface (+ version) it corresponds to — the "is this in the language"
   judgement happens **once, at row-authoring time** (with `~/Documents/OSS/clojure/`
   as evidence recorded in the note), NOT re-derived from the pinned clone on every
   gate run. This keeps the gate **reproducible + fully in-repo** (the DA's decisive
   refinement — see below).

2. **Single read point** — `src/runtime/host_interface.zig` (Layer 0, neutral)
   exposes the recognition + routing surface as a `StaticStringMap` generated/
   checked from `host_interfaces.yaml`. The macro (`isHostMarker`), the canonical-
   name resolver, and the method-wiring guard all read from this one module. The 5
   scattered `std.mem.eql("Object")` sites are deleted in favour of it.

3. **Gate — `scripts/check_host_interface.sh`** (sibling to G1/G2/G3, runs in
   `test/run_all.sh`):
   - **(i) Set bound**: every name recognised in code (the `host_interface.zig`
     table) ⊆ the rows in `host_interfaces.yaml`. A name cannot be recognised
     without a row whose `derives_from:` justifies it as language-defined — so
     libraries cannot drive growth beyond the definition.
   - **(ii) Route soundness** (the real anti-個別最適化 lever): every row whose
     `routes_to`/`wires_to` names a cljw protocol must point to an **actually-
     modeled** protocol. You cannot recognise a name without a *generic* dispatch
     surface behind it — a per-library shim has no slot. Unwired methods carry
     `status: feature_not_supported` (explicit transient per ADR-0018), never a
     silent drop.

4. **Two facets of `Object` coexist (refined during implementation,
   2026-06-07)**: the implementing cycle (D-278) found that `java.lang.Object`
   has *two distinct facets* — (a) the **deftype/reify supertype marker** (this
   ADR's concern → `host_interfaces.yaml`) and (b) the **class reservation** for
   `(instance? Object x)` / `(class x)` (the `compat_tiers.yaml host_classes`
   `java.lang.Object` row, served via `class_name.zig`). The DA's "migrate the
   row out" advice conflated the two; deleting the class-facet reservation would
   risk the instance?/class surface. The finished-form resolution: the two facets
   live in two SSOTs (which *reinforces* the one-SSOT-per-concern argument) — the
   `host_classes` `java.lang.Object` row STAYS (class facet), and
   `host_interfaces.yaml` owns the marker facet, with a cross-note on each.

5. **Sequencing**: this SSOT + gate lands **before** D-275 slices 3+
   (`clojure.lang.*`). After it, adding an interface is "author a row + wire its
   protocol", gate-checked — never a new `eql` site. 網羅 the *recognition table*
   up-front (cheap, closed); wire impl *incrementally* (each generic + gated) —
   the F-013 clause-4 reconciliation of comprehensiveness vs binary/startup cost.

## Alternatives considered

Devil's-advocate subagent output (verbatim, fresh context, F-NNN envelope):

> **F-NNN reachability note (leading entry, per the brief):** No finished-form-clean option here requires violating any F-NNN. All three alternatives below sit inside the envelope. The genuine tension is not F-NNN-vs-clean; it is *which table is the SSOT* and *what the gate's closed set is derived from*. I flag one place where the proposed shape risks a subtle F-009 / F-013 violation (a `routes_to` table that becomes a dispatch map living in `compat_tiers.yaml`) and route around it in the recommendation.
>
> ### Alternative 1 — smallest-diff: single shared `StaticStringMap` in one Zig file, no YAML, no gate
>
> Collapse the 5 scattered `std.mem.eql` sites into one `host_marker.zig` (Layer 0, `runtime/`) exposing `recognize(name) -> ?HostMarker` where `HostMarker` is an enum (`.object`, future `.seqable`, `.ilookup`, …) plus a `routesTo()` method. The macro asks "is this a marker" (non-null), the primitive asks "what does it route to". The alias set (bare + `clojure.lang.`-qualified) lives in the `initComptime` table.
>
> - **Better than proposed:** Zero new YAML schema, zero new gate script, zero cross-file SSOT drift risk. The recognition logic and the routing logic are co-located in the one file a reader greps for — arguably *more* discoverable than a YAML row that points at a Zig table that points at a protocol. It directly kills the "5 scattered `eql` sites" problem, which is the ADR's stated structural target. It is also the most F-009-honest: the marker→family map is implementation, and implementation belongs in neutral `runtime/`, not in the cross-reference index.
> - **What it breaks:** It does **not** structurally close the 個別最適化 entry — the thing F-013 and the user most want. Adding `IDeref` is still "append one enum arm + one table row in one file," which is exactly the library-by-library growth temptation, just centralized. Nothing *mechanically prevents* a future loop from adding `.some_lib_specific_iface` because a lib needed it. There is no gate asserting the set ⊆ the language-defined set, and no gate asserting every route points at a real modeled protocol. It solves the *scatter* smell but not the *unbounded-growth* smell. Against F-013's "raise the system one level" bar, this is a refactor, not a structural defense.
>
> ### Alternative 2 — finished-form-clean: dedicated `host_interfaces.yaml` SSOT + generated Zig table + the two gates, NOT folded into `compat_tiers.yaml`
>
> Same closed-set + dual-gate idea as the proposed shape, but the SSOT is a **new dedicated file** `host_interfaces.yaml` (sibling to `compat_tiers.yaml` / `placement.yaml`), not an extension of `host_classes`. Each row: `{name, aliases: [bare, clojure.lang.X], routes_to, tier, status}`. The Zig `StaticStringMap` is generated/checked from it; `scripts/check_host_interface.sh` enforces (i) set ⊆ language-defined supertypes and (ii) every `routes_to: <protocol>` resolves to a modeled cljw protocol.
>
> - **Better than proposed:** Respects the role-split that the project already codified. `compat_tiers.yaml`'s own header (and the `placement.yaml` cross-reference in CLAUDE.md) draws the line explicitly: **`compat_tiers.yaml` = Java/cljw *Class*-level surface; `placement.yaml` = Clojure-ns *var*-level**. Host-supertype *markers* are a third category — they are neither real classes (ADR-0059/AD-003 says `Object`/`clojure.lang.*` are NOT host classes) nor vars. Folding them into `host_classes` forces the schema to host rows that *contradict the schema's own premise* (`host_classes` rows model classes that `(instance? …)` and ctor-resolution treat as real; these markers are explicitly not-real). A dedicated SSOT keeps each index honest about what it indexes — which is the same discipline `accepted_divergences.yaml` and `feature_deps.yaml` already embody (one SSOT per concern). The two gates deliver the F-013 "网罗 from the definition, no per-lib slot" structural close that Alt 1 cannot.
> - **What it breaks:** A fourth top-level YAML SSOT raises the scaffolding surface `audit_scaffolding` must sweep, and adds a `yq`/parser recipe + a new gate to `test/run_all.sh` (G4, after G1/G2/G3). The framework_completion.md rule then obligates this cycle to also run a discovery sweep + retrofit (the `Object` row currently living in `host_classes` must migrate out, and any other latent marker references must be found). That is more work than extending an existing schema — but per F-002 that is not a reason to reject it.
>
> ### Alternative 3 — wildcard: no marker table at all; model the families as real zero-method MARKER protocols in bootstrap `.clj`, recognized through the existing protocol path
>
> The codebase already has the machinery: `addProtocolImpl` records zero-method MARKER protocols (`Sequential`, per the D-190/ADR-0068 comment at protocol.zig:258-262). Push that further — define `Object`, `Seqable`, `ISeq`, `ILookup`, etc. as **actual cljw protocol Vars** in a bootstrap namespace (e.g. `clojure.lang` ns shipped in `lang/clj/`), each with the method set it routes to. Then `deftype`/`reify`/`extend-type` need **no special marker recognition at all** — the names resolve through the ordinary protocol-Var path (the existing `.protocol` arm), and the `.symbol` host-marker arm + all 5 `eql` sites **delete entirely**. `Object/toString` becomes a real protocol method dispatching to the str/print consult.
>
> - **Better than proposed:** This is the deepest "raise the system one level" reading of F-013 — it doesn't *recognize* markers, it *eliminates the marker concept*. The 5 scattered sites don't get consolidated; they cease to exist. Recognition, routing, and the "is it modeled" question all collapse into "does this protocol Var exist and is it satisfied," which is machinery the runtime already has and tests. No new YAML, no new gate, no closed-set-derivation maintenance question at all — the closed set IS "what bootstrap defines," enforced by the fact that an undefined name is an ordinary unresolved-Var error. It is maximally F-009-clean (impl is protocols-over-primitives, the project's blessed Phase-7.2 pattern per ADR-0008 amendment 2).
> - **What it breaks:** Three real problems. (a) `Object` is *not* a protocol in any normal sense — making it a cljw protocol Var means every type "satisfies Object," which needs a universal-satisfy short-circuit that is itself a special case (you've moved the special-casing, not removed it). (b) JVM semantics: in real Clojure these names are interfaces the *runtime* implements on built-in types, not protocols user code extends; a bootstrap-protocol model can drift from `clj` behaviour (F-011 risk) for `(satisfies? clojure.lang.ISeq x)`-style probes that real libraries do issue. (c) It front-loads a large bootstrap-`.clj` + dispatch-wiring effort before the marker set is even enumerated, and offers no gate preventing a future loop from defining a *per-library* marker protocol — the 個別最適化 door is still open, just relabeled as "define a protocol." Without a closed-set gate, Alt 3 regresses on the exact structural property F-013 demands.
>
> ### Recommendation (within F-NNN)
>
> **Adopt Alternative 2 — the dedicated `host_interfaces.yaml` SSOT with the two gates — over the proposed `host_classes` extension.** The proposed shape's *mechanism* (closed-set derivation + dual gate) is correct and is the only candidate that mechanically closes the 個別最適化 door F-013 targets; Alt 1 leaves the door open and Alt 3 both leaves it open and risks F-011 drift on `Object`/`satisfies?`. The single change I'd make to the proposed shape is the **home**: not `compat_tiers.yaml host_classes`. That schema's own documented contract is "Class-level Java surface," and ADR-0059/AD-003 explicitly declares these marker names are *not* host classes — so a `host_classes` row asserting `Object` as a class-level entry is self-contradictory and will confuse `cljw --list-host-classes` (which enumerates real surfaces). A dedicated SSOT mirrors the project's established one-SSOT-per-concern discipline (`accepted_divergences.yaml`, `feature_deps.yaml`, `placement.yaml`) and keeps the `routes_to` dispatch knowledge out of the cross-reference index — important because a `routes_to: <protocol>` column folded into `compat_tiers.yaml` would make the index a *dispatch map*, brushing against F-009 (impl detail leaking into the authoritative cross-reference). The extra YAML + G4 gate + framework_completion retrofit is more diff than extending `host_classes`, and per F-002 that is explicitly not a reason to prefer the smaller shape.
>
> ### On the "closed set derived from pinned Clojure source" maintenance question (explicitly assessed)
>
> This is the proposed shape's weakest seam and the ADR should address it head-on. Deriving the gate's allowed set from `~/Documents/OSS/clojure/` couples the gate to a **pinned reference clone** that is read-only and not version-tracked inside this repo. Two concrete hazards: (1) When the pinned Clojure version bumps, the `clojure.lang.*` interface roster can shift (interfaces get added across Clojure versions — e.g. `IKVReduce`, `IReduceInit`, `IDrop` arrived in different releases), so a gate that re-derives "legal supertypes" from whatever clone is on disk is **non-reproducible** and can flip green→red on an unrelated clone update. (2) The clone is a *survey textbook* per `reference_clones.md`, explicitly "do not treat as load-bearing" — wiring a hard gate to it elevates a survey input to a build dependency, which the project's own rules discourage. **The clean fix:** the closed set should be **materialized into `host_interfaces.yaml` itself** (the rows ARE the closed set, each with a `derives_from:`-style note citing which Clojure interface/version it corresponds to — mirroring `accepted_divergences.yaml`'s `derives_from` discipline), and the gate enforces "recognized-in-code ⊆ rows-in-YAML" — a fully in-repo, reproducible check. The "is this in the language" judgement happens *once, by a human/loop at row-authoring time* (with the pinned clone as evidence, recorded in the row's note), not *every gate run against a mutable clone*. That converts the version-coupling maintenance burden into an explicit, reviewable, version-pinned row — and makes the gate deterministic. The second gate ("every `routes_to: <protocol>` points at a modeled cljw protocol") is sound as proposed and needs no change; it is the real anti-個別最適化 lever, since it forces "model a generic protocol first" before any name can be recognized.

### Main-loop disposition (within the F-NNN envelope; the DA is advisory, not binding)

**Adopted from Alternative 2 (the DA's recommendation):** (1) a **dedicated
`host_interfaces.yaml`** SSOT, NOT a `compat_tiers.yaml host_classes` extension —
the role-split (Class-level vs marker) and the ADR-0059 "not a class" premise make
folding self-contradictory; (2) the **two-clause gate** (set-bound + route-
soundness), with route-soundness as the primary anti-個別最適化 lever; (3) the
DA's decisive refinement — **the closed set is materialized in the YAML rows**
(each with a `derives_from:` note), and the gate checks "recognised-in-code ⊆
YAML rows", so it is reproducible and in-repo, NOT re-derived from the mutable
pinned clone every run; (4) the legacy `host_classes` `java.lang.Object` row
STAYS as the class facet (refined during implementation — see Decision 4; the
DA's "migrate out" conflated the marker and class facets).

**Diverged from / not adopted**: Alternative 1 (no gate — leaves the unbounded-
growth door open, fails F-013 clause 3) and Alternative 3 (model-as-real-protocols
— moves rather than removes the `Object` special case via a universal-satisfy
short-circuit, and risks F-011 drift on `(satisfies? clojure.lang.ISeq x)`; also
leaves the growth door open with no closed-set gate). Alt 3's *insight* (route a
marker to a generic protocol surface) is preserved inside Alt 2's route-soundness
gate, without making `Object` itself a protocol Var.

## Consequences

- **The 個別最適化 entry is structurally closed**, not watched: a new
  `clojure.lang.*` interface requires a `host_interfaces.yaml` row (gate (i):
  justified as language-defined) wired to a generic modeled protocol (gate (ii):
  no per-library shim slot). Adding `or eql("X")` at a code site is impossible —
  there is one read point, and an unrowed name fails the gate.
- **The 5 scattered `eql("Object")` sites collapse to one module.** D-275 slice 1's
  hand-coded recognition (the smell noted in its commit) is retired by the
  implementing cycle.
- **Coverage trends monotonically (F-013 clause 2):** each interface wired is a
  *generic* protocol reusable by every type + user code, so one library's gap-fix
  improves the next library's odds — not a one-library shim.
- **`derives_from` makes the closed set reviewable + reproducible.** The gate never
  reads the pinned Clojure clone at run time; the clone is evidence cited in the
  row, mirroring `accepted_divergences.yaml`'s discipline.
- **New scaffolding surface**: a 4th top-level YAML SSOT + a G4 gate
  (`check_host_interface.sh`) + `audit_scaffolding` sweep coverage. The
  framework_completion.md "new discipline ⇒ discovery + retrofit" obligation is
  satisfied by the scatter consolidation in the implementing cycle (D-278): the
  5 `std.mem.eql("Object")` sites are the complete existing population, all
  migrated to the single read point in the same commit (no 2-tier residue).
- **D-276** (`extend-type Object` as-target = default-for-all-types) becomes a
  `host_interfaces.yaml` row routed to a default-method dispatch tier, not a
  separate `eql` special-case.
- **Binary/startup (F-013 clause 4, D-277)**: 網羅 applies to the *recognition
  rows* (cheap — no impl), not to eager impl loading; the eager-vs-lazy modeling
  tension stays tracked in D-277, revisited only if the cold-start / size mission
  target is threatened.
- **This ADR is the first mechanical instance of F-013 clause 3.** Future hand-
  maintained capability allowlists (should any arise) cite this pattern: closed-
  set SSOT (keys from the definition) + a gate bounding the set + a gate requiring
  a generic route.

## Revision history

### Amendment 1 (2026-06-10) — editable / transient collection family (D-286)

The closed set absorbs the **editable / transient collection interface family**
unchanged (no new ADR; the ADR-0102 mechanism is the right shape): 7 new
`protocol_remap` rows — `IEditableCollection`, `ITransientCollection`,
`ITransientAssociative`, `ITransientMap`, `ITransientSet`, `ITransientVector`,
and `IPersistentSet` (the last as the **D-286b** work-fix). 6 new cljw
`defprotocol`s back the transient targets (cljw had no transient protocol Var;
transients are native Value tags). Driven by `flatland.ordered` (F-010/F-013
library-discovery): `OrderedSet` declares `clojure.lang.IEditableCollection`
(the prior LOAD blocker at set.clj:95) + `IPersistentSet` with clj-named
methods, and the `Transient*` types declare the `ITransient*` family.

**Two mechanism changes** beyond the data rows:
1. **Bare aliases route through `protocol_remap`.** A deftype `:import`s
   `(clojure.lang IEditableCollection …)` and declares the BARE simple name, so
   both the bare and qualified spellings are MARKERS keys → the same row.
2. **Self-targeting recursion guard** (`sectionNeedsRemap`, macro_transforms.zig).
   `IPersistentSet`/`ITransient*` remaps self-target (`disjoin`→IPersistentSet/
   `-disjoin`), and the D-283 dual-registration re-emits the original clj name, so
   the emitted section carried BOTH `-disjoin` (cljw) and `disjoin` (clj) and
   re-routing translated `disjoin`→`-disjoin` forever (stack-overflow segfault).
   The guard: a section carrying any already-cljw method *under the interface's own
   protocol* is the rewrite's second pass → register directly, don't re-route. A
   same-name-but-different-protocol remap (`equiv`→Object, `hasheq`→Object) is NOT
   identity → still routes. This generically resolves the D-286 barrier's "harder
   part" (a bare name that is BOTH a cljw protocol Var AND needs clj→cljw method
   translation).

**Disposition: LOAD-LEVEL + the D-286b dispatch fix** (DA Alt 2). Recognition lets
the family LOAD; D-286b makes ordered's declared clj-named methods DISPATCH
(verified: `conj`/`seq`/`count` on a deftype `IPersistentSet`). The native
`conj!`/`assoc!`/`persistent!`/`disj!` + `into`/`-editable?` typed_instance consult
is deferred to **D-369**, an honestly off-critical-path follow-up: cljw's `into`
branches on `-editable?` (native-tag-only), so a user editable type takes the plain
`conj` path and NEVER reaches the transient surface — wiring it does nothing for
`(ordered-set …)` today. ordered.set now advances past ALL its editable/transient
interfaces to its next, SEPARATE blocker `print-method` (a clojure.core multimethod
gap, D-370) — NOT claimed "fully working".

#### Alternatives considered (Devil's-advocate fork, verbatim-reflected)

The DA fork found a load-bearing fact the survey missed and it reframed the
decision. Recorded faithfully:

- **Critical finding:** ordered's public api `(ordered-set 1 2 3)` → `(into
  empty xs)` → cljw `into` branches on `-editable?` (NOT `(instance?
  IEditableCollection)` like JVM); `-editable?` is native-tag-only → returns
  false for a `.typed_instance` → the transient path is NEVER entered. So the
  transient-dispatch wiring (the proposal's deferred follow-up) is genuinely OFF
  the critical path, and the REAL work-blocker is D-286b (clj-named methods
  mis-registering), which IS on the critical path.
- **Alt 1 — smallest-diff (LOAD-LEVEL only, defer D-286b too):** lands the family
  recognition big-bang; matches the IFn/IObj/Sorted "load-level" precedent. BREAKS:
  leaves ordered LOADABLE-BUT-BROKEN and mis-attributes the residual blocker — the
  Defer-to-amnesia / false-positive-discharge class (the exact over-claim the D-286
  row already committed once).
- **Alt 2 — finished-form-clean (LOAD-LEVEL + D-286b same cycle; transient consult
  a genuine follow-up):** the disposition that makes the driver WORK, not merely
  load (F-013/F-011 bar). The clj-name disambiguation is a COMMONISED mechanism
  (fixes every bare-named-interface deftype, F-011 clause 1), not a per-lib shim.
  Larger diff — but diff size is not a valid reason to prefer smaller (F-002/F-011
  clause 5). **DA recommendation.**
- **Alt 3 — wildcard (wire `-editable?`/`into` to consult IEditableCollection on
  typed_instances now):** deepest F-011 reading (user editable types ride the
  transient fast-path like JVM); closes the `-editable?` native-tag divergence at
  the root. BREAKS: still needs Alt 2's D-286b; front-loads the most machinery +
  a silently-wrong-`into` hazard; the `-editable?` divergence is a DISTINCT
  finished-form concern deserving its own ADR/AD — bundling it over-scopes this
  cycle. Recorded as the D-369 follow-up (transient consult + `-editable?`
  typed_instance detection, OFF the ordered critical path).
- **No F-NNN-violating option** was required; all three sit in the envelope.

### Amendment 2 (2026-06-10) — java.util methods grouped under a clojure.lang section (D-372)

clj's `IPersistentMap`/`IPersistentSet`/`IPersistentVector` **extend**
`java.util.Map`/`Collection`/`java.lang.Iterable`, so a library may place java
methods (`iterator`/`entrySet`/`keySet`/`values`/`size`/…) UNDER its
`clojure.lang.*` deftype-supertype section instead of a separate `java.util.*`
section (flatland.ordered.map's OrderedMap declares `iterator`/`entrySet` under
its IPersistentMap section). `rewriteProtocolRemap` raised `feature_not_supported`
for any method with no remap target.

**Decision (DA Alt A): ACCEPT-AND-DROP the java method, load-level.** A new closed
set `host_interface.isJavaUtilMethod(name)` (derived from java.lang.Iterable +
java.util.{Collection,Map,List} read/iteration definitions — F-013); when an
unmapped `protocol_remap`-section method is in it, `rewriteProtocolRemap` drops it
(no registration, no emitted section) instead of raising. This is the **ADR-0103
`host_inert` accept-don't-dispatch rule at METHOD granularity**: a whole
`java.util.Map` section is already dropped wholesale, and the disposition must be
identical whether the author groups the same methods under a java section or a
clojure.lang section (a cosmetic placement choice must not change cljw behaviour).
A genuinely-unwired *clojure.lang* method (not in the java set) still raises — the
F-013 discovery mechanism survives. **Scope: read/iteration only**; a persistent
type's java mutators (`put`/`add`/`clear`/`remove`) throw on the JVM too, so an
unmapped mutator correctly still raises (closer parity than dropping).

**Not a `permanent_noop_forbidden` violation**: the drop removes a *registration*
(a later `(.iterator x)` is DECLINED with method-not-found), it does NOT install a
success-masking no-op that *answers* the call. The dropped body
(`(SeqIterator. …)`) is JVM-only/unrunnable in cljw (ADR-0059) and no cljw caller
reaches it. Recorded as **AD-027** (accepted_divergences.yaml) with a pin
(`test/e2e/phase14_java_method_grouping.sh` case 2: a dropped method is declined,
never silently run). `isJavaUtilMethod` carries a `derives_from`-style doc block
citing the java interface definitions (the Alt-A "set lives in code" seam the DA
flagged — closed by the comment; a future gate clause may bound it like gate (i)).

#### Alternatives considered (Devil's-advocate fork, verbatim-reflected)

> Fresh-context DA-fork (agent a7ac0278570032884), F-NNN envelope. The spike
> (Opt B implemented + validated: ordered.map parses past the iterator/entrySet
> grouping, next blocker unrelated `Map$Entry`) preceded the fork per ADR-0089.

**Leading F-NNN entry:** no option requires violating an F-NNN. The real tension
is whether ACCEPT-AND-DROP is sound parity with ADR-0103 or a silent semantic drop
`permanent_noop_forbidden` forbids — assessed head-on: the NG criterion is "user
sees success while semantics are silently dropped." ACCEPT-AND-DROP passes because
(1) the dropped body is JVM-only by construction (constructs `clojure.lang.SeqIterator`,
unrunnable in cljw, no cljw caller reaches it); (2) it is the ADR-0103 rule at finer
granularity, making section-placement irrelevant (a consistency fix, not a
loosening); (3) it is observably honest — a `(.iterator m)` call gets method-not-found,
NOT a plausible wrong value (it DECLINES, it does not no-op-answer). The one guardrail
to keep: the drop stays bounded to the java.util/lang closed set.

- **Alt A — closed-set drop (implemented):** the minimal *coherent* fix (placement
  irrelevant); definition-derived (F-013 — unlocks the 15+ data-structure libs that
  group java methods under clojure.lang sections: finger-tree/core.cache/rrb-vector/
  avl/priority-map/int-map/gvec, not just ordered.map); reuses ADR-0103 semantics at
  a finer node; unmapped-clojure.lang still raises (discovery survives). Risk: the set
  is a code `StaticStringMap`, not gated YAML rows — mild ADR-0102-discipline seam;
  bounded because small + definition-derived. **DA recommendation.**
- **Alt B — map java read methods semantically** (entrySet→seq, keySet→keys,
  size→count…) so `.size`/`.keySet` dot-calls dispatch. Better: deepest F-011 for the
  analogue-having subset. Loses decisively: (1) **re-introduces the `size`/`count`
  collision ADR-0103 made impossible by construction** (ordered.map declares `count`
  under IPersistentMap; mapping its `size`→`-count` = duplicate `(IPersistentCollection,
  -count)` last-wins hazard); (2) `iterator`/`entrySet` have NO sound cljw target
  (no Iterable protocol; entrySet returns JVM `Map$Entry` — the very next blocker), so
  B cannot even replace A, only add surface on top; (3) "should a no-JVM runtime expose
  `.size`/`.keySet`" is its own AD/ADR (AD-003), over-scoping this cycle. Diff size is
  NOT why B loses (F-002) — the collision re-introduction + no-sound-target are. B's
  insight is a separate follow-up D-NNN.
- **Alt C — wildcard: drop ANY unmapped method (no closed set).** Better: zero
  maintenance. **The F-013-clause-3 forbidden open-set posture**: a genuinely-unwired
  *cljw* protocol method (a real gap cljw should model) would be silently dropped instead
  of surfacing — destroys library-driven discovery (the next lib re-buries it); also masks
  clj-rejected typos (F-011 divergence that HIDES errors). The symmetric finding to
  ADR-0103's own DA. **Reject.**

**Recommendation: Alt A as implemented**, scoped read/iteration-only. Fold in: (1)
an AD-NNN with a pin (done — AD-027); (2) a `derives_from` comment on the closed set
(done) [+ a future gate clause is optional]. Reject B (ADR-0103 collision + no sound
target + over-scope) and C (open-set inverts F-013 clause 3).
