# ADR-0068 — `Sequential` marker protocol drives seq-print + `sequential?`; record map-style print form (D-190)

- **Status**: Proposed → Accepted (2026-06-01)
- **Discharges**: D-190 (eduction prints `#Eduction[..]` not `(2 3 4)`; record
  prints `#Pt[1 2]` not `#user.Pt{:x 1, :y 2}`). Also closes the latent
  `(sequential? eduction)` → `false` divergence (clj: `true`).
- **Related**: ADR-0067 (`eduction` as a `deftype`), ADR-0008 (protocol +
  multimethod dispatch), F-002 (finished form wins), F-009 (impl neutrality /
  zone layering), F-011 (behavioural equivalence to Clojure JVM, commonisation
  over effort), D-189 (Seqable→seq coercion), D-058/D-079 (ns surface — the
  record-fqcn ns-prefix residual is parked there)
- **Defers**: user-extensible `print-method` multimethod (open dispatch,
  `(defmethod print-method MyType …)`) to a future ADR — see § Deferred.

## Context

`(eduction (map inc) [1 2 3])` prints `#Eduction[#<fn_val> [1 2 3]]` in cljw
but `(2 3 4)` in Clojure; `(->Pt 1 2)` for `(defrecord Pt [x y])` prints
`#Pt[1 2]` not `#user.Pt{:x 1, :y 2}`. The VALUE is correct in both cases
(`into`/`reduce`/`seq`/`first` all match — ADR-0067); only the `prn`/`pr`
PRINT FORM diverges.

**Architecture (verified in-repo).** `prn`/`pr`/`pr-str` are Zig primitives
(`src/lang/primitive/core.zig`) that funnel through one sink:
`print_mod.printResult(rt, env, w, v)` (Layer-0 `src/runtime/print.zig`).
`printResult` already carries `rt`+`env`. It calls `deepRealize` (realizes
`.lazy_seq`/`.list`/`.vector`; `else => return v`, so a `.typed_instance`
passes through unrealized) then the pure `printValue`, whose `.typed_instance`
arm is `printTypedInstance` → `#<fqcn>[field0 field1 …]` (values only). That
single default is the source of BOTH divergences.

**Two stages, two bug kinds (the crux).** The eduction bug is a
**realization miss** (deepRealize's `else` swallows the `.typed_instance`);
the record bug is a **rendering default** (`#fqcn[..]` instead of map-style).
cljw has materialised what Clojure expresses through one `print-method`
interface as **two distinct stages**: `deepRealize` (realization, has rt) then
`printValue` (rendering, pure). The two bugs live in those two stages.

**The discriminator is `Sequential`, not `Seqable` (oracle-verified).** A
record is `[sequential? false, seqable? true]` yet prints map-style; an
eduction is `sequential? true` and prints as its seq. So "print as a seq" ⟺
`Sequential`, NOT `Seqable` (realizing every Seqable typed_instance would wrongly
turn a record into its entry-seq). cljw has **no `Sequential`** (grep: 0 hits as
a protocol; `sequential?` is a hard-coded tag switch with `else => false`, so
`(sequential? eduction)` is wrongly `false`). Clojure's `Sequential` is a
**marker interface** (zero methods). cljw's `defprotocol` currently **rejects**
zero-method protocols (`args.len < 2` guard) — but JVM allows `(defprotocol
Marker)` with `(satisfies? Marker x)` → `true` (oracle-verified), so accepting
markers is behavioural equivalence, not a new divergence.

cljw already has a full `MultiFn` infrastructure (`multimethod.zig`, JVM
`clojure.lang.MultiFn`-equivalent: dispatch fn / method table / prefer table /
hierarchy / cache; `defmulti`/`defmethod`/`prefer-method` work). The MultiFn
doc-comment even names `clojure.core/print-method` as its example. So the full
`print-method`-as-multimethod finished form is *reachable* — but it additionally
requires a print-recursion layer relayer (the recursive descent lives in Layer-0
`printValue`; a Clojure multimethod is Layer-2) and user-extensibility that
D-190's bug does not need. See § Deferred + § Alternatives.

## Decision

Fix each bug in its architecturally-correct existing stage, with a real
`Sequential` marker as the realization discriminator. One marker, two
consumers (print-realize + `sequential?`) — F-011 commonisation.

1. **Relax `defprotocol` to accept zero-method marker protocols.**
   `expandDefprotocol` guard `args.len < 2` → `args.len < 1` (a name suffices;
   empty `method_sigs` expands to `(rt/__make-protocol! 'name [])`). JVM-faithful.
   Update the `defprotocol_form_incomplete` template to drop "and at least one
   method signature".

2. **Define `(defprotocol Sequential)` marker in core.clj**, and extend it on
   `Eduction` (and any seq-family `deftype` that should print as a seq). The
   `deftype`/`reify` descriptor builder already records "one entry per declared
   interface" in `protocol_impls` independent of methods, so the marker
   registers.

3. **Commonise `sequential?`** (`core.zig:sequentialQ`): keep the native-tag
   fast path; ADD — for a `.typed_instance` — a `Sequential`-in-`protocol_impls`
   check. `(sequential? eduction)` → `true`, matching clj. The same marker the
   print path consumes drives the predicate (no second source of truth).

4. **print.zig — realize (eduction):** `deepRealize` gains a `.typed_instance`
   arm: if the descriptor satisfies `Sequential`, drive the existing
   `lazy_seq_mod.seq` realize loop (the one the `.lazy_seq`/`.list` arm uses) →
   a list → prints as `(2 3 4)`. Zone-legal: print.zig (Layer-0) reads
   `descriptor.protocol_impls` directly / calls `dispatch.zig` (Layer-0); it does
   NOT import `lang/`.

5. **print.zig — render (record):** `printTypedInstance` branches on
   `inst.descriptor.kind == .defrecord` → emit `#<fqcn>{:name val, …}` from
   `field_layout` (declared field names) + `fields()`; else the existing
   `#<fqcn>[..]`. Pure (no rt). Declared fields only — assoc'd extra keys
   (`__extmap`, D-086) are a separate residual.

### Why this is the finished form for D-190's scope (not smallest-diff bias)

The discriminator is the REAL one (`Sequential`), JVM-faithful, not a `kind`
heuristic. It is commonised: one marker drives both print and `sequential?`
(F-011). Each fix sits in its architecturally-correct stage. And it is a genuine
**shrinking** skeleton toward the deferred `print-method` multimethod: the
`Sequential` marker, the deepRealize-realize arm, and the record renderer all
survive verbatim as that multimethod's `:default` / `Sequential` / record method
bodies (DA-confirmed). The scope boundary is answered on merits, not diff size:
"is *user-extensible* `print-method` in D-190's finished form?" → No; overriding
how a type prints is a separate feature from cljw's own types printing correctly.

## Deferred (future ADR, not this cycle)

- **User-extensible `print-method` multimethod.** `(defmethod print-method
  MyType …)` is unsupported until a future ADR routes the print sink through a
  real `print-method` `defmulti` (reusing the existing MultiFn) and decides the
  print-recursion layer (lift the recursive renderer to Layer-2, or keep the
  Layer-0 default + a Layer-2 override seam). The three pieces above become its
  method bodies. `print-dup` and exotic `prefer-method` nuances are out of scope
  there too (recorded DIVERGENCE — avoids an excessive skeleton now).

## Scope / recorded divergences

- **Record fqcn ns-prefix.** This cycle renders `#Pt{:x 1, :y 2}`; clj renders
  `#user.Pt{:x 1, :y 2}`. The `{:k v}` map shape is the D-190 fix; the `user.`
  ns-prefix depends on the ns surface and is parked on D-058/D-079 (F-003
  structural-deferred). Residual, recorded.
- **Plain non-Seqable `deftype`.** clj prints `#object[user.Foo 0x… "…"]`; cljw
  prints `#Foo[..]`. Untouched here — a separate acceptable divergence (cljw's
  form is arguably more useful and is not D-190's subject).

## Alternatives considered

(Devil's-advocate fork, fresh context, F-002/F-009/F-011 envelope. Reflected
verbatim; recommendation is non-binding — the main loop chose Alt 3 sharpened
with a real `Sequential` marker, having answered the scope question against
near-term user-extensible `print-method`.)

### Alt 1 — Smallest-diff: two arms in the Zig printer

Touch only `print.zig`. (i) `deepRealize` `.typed_instance` arm: if the
descriptor is `Seqable`/`IReduce`-bearing (or `kind != .defrecord`), drive the
seq loop → eduction prints `(2 3 4)`. (ii) `printTypedInstance` branches on
`kind == .defrecord` → `#fqcn{:field val …}`; else `#fqcn[..]`. No core.clj
change, no new var.
**Better:** stays in the single sink → trivially F-011-correct (one site); zero
layering risk; no new dispatch dep, no Clojure↔Zig seam.
**Breaks:** the dispatch logic ("is this a seq? a record?") is hard-coded in the
Zig printer **by `kind` enum**, not by the value's own protocol participation —
the exact "ad-hoc per-site patch" F-011 names as the failure mode. The next
printable type (custom-print deftype, future `IPrintable`, `print-dup`) forces
ANOTHER arm. The print decision lives in the wrong layer (printer enumerates
types vs the value's type says how it prints). It accretes; does not generalise.
**F-NNN:** F-011 ✅ sink-commonisation but ❌ *mechanism* commonisation. F-009 ✅
(Layer-0 only). F-002 ❌ — smallest-diff a finished-form owner unwinds at the
third printable type; *enlarges* the eventual rewrite, so not an endorsable
skeleton.

### Alt 2 — Finished-form-clean: `print-method` as a real multimethod

Define `print-method` as a genuine `defmulti` (dispatch on `(class x)`), reuse
the existing `MultiFn`. `:default` method = thin primitive calling the Zig
`printValue` (scalars + collection literals stay Zig). Add a record method
(map-style) and a `Sequential` method. **Seam to build:** `prn`/`pr-str`/`pr-on`
route through the `print-method` var (the Layer-2 primitive resolves+invokes the
var), AND `Sequential` must be created as a real marker, and Eduction re-tagged
to carry it.
**Better:** JVM-faithful — `print-method` *is* a multimethod; records/Sequential
*are* methods; user `(defmethod print-method MyType …)` for free. F-011's "single
shared mechanism" satisfied at the *mechanism* level (open dispatch).
**Breaks/costs:** two new structural commitments larger than the bug. (1) A
**Zig-primitive → Clojure-var call seam** at the sink — `print.zig` is Layer-0
and may not import `lang/`; the recursive descent (nested values) must re-enter
`print-method` per element, so either a Layer-0/Layer-2 ping-pong or lift the
whole recursive renderer to Layer-2. (2) **`Sequential` marker must be invented**
anyway (separate structural feature) + Eduction re-tagged. **Perf:** every nested
print element pays a multimethod dispatch (cache helps, but vs a Zig switch it's
real). Genuinely finished-form-clean — but its finished form is *larger than
D-190*: it pulls in `Sequential` AND a print-recursion relayer AND user
extensibility.
**F-NNN:** F-011 ✅✅ (true open mechanism). F-009 ⚠️ solvable but load-bearing
(renderer's home layer must be decided). F-002 ✅ this is the finished form **for
the print SUBSYSTEM** — but D-190's scope is a strict subset; adopting it means
D-190 grows into "print-method subsystem", endorsable under F-002 (big surgery is
the default) **provided `Sequential` is built as a co-requisite, not stubbed.**

### Alt 3 — Wildcard: the two-mechanism hybrid, made principled

Accept that record-print and eduction-print are **two mechanisms** and route
each by its actual nature. **Eduction:** fix at `deepRealize` generically —
realize any value that participates as a seq (drive `lazy_seq_mod.seq`), one
general "realize seqable" arm, not an Eduction special-case; prints through the
existing list printer; no new marker. **Record:** a *pure* `#fqcn{:k v}` render in
`printTypedInstance` keyed on `kind == .defrecord` + `field_layout`; needs no rt,
no dispatch.
**Better:** honest about the real two-concern split — eduction-print is a
**realization** problem (shares the deepRealize seq-walk; F-011-common with
lazy_seq/list), record-print is a **rendering** problem (pure field formatting).
Forcing them into one multimethod (Alt 2) is itself a mild conflation (the
Sequential method body just re-seqs = realization wearing a rendering hat). Puts
each concern where it already belongs; no new marker, no Zig→Clojure seam, no
perf regression; smaller than Alt 2 yet not Alt 1's ad-hoc, because the eduction
arm is the *general* realize-seqable arm (covers future Seqable typed_instances).
**Breaks/costs:** no user-extensible `print-method` (recorded DIVERGENCE). If the
finished form wants open printing, Alt 3 is a way-station Alt 2 subsumes —
cleanly: Alt 3's two pieces survive as Alt 2's method bodies. Record-print stays
a Zig `kind` branch — defensible (records are a *core* type with fixed print
syntax; Clojure hardcodes record print in `core_print.clj` too).
**F-NNN:** F-011 ✅ (eduction arm is the shared seqable-realize mechanism; record
render is the inherent core formatter, not a comment-apology local fix). F-009 ✅
(Layer-0, rt present, no seam). F-002 ⚠️ clean **iff** user-extensible
`print-method` is not in the near-term finished form; if it is, Alt 3 is a
skeleton-toward-Alt-2 (acceptable *because it shrinks* Alt 2's rewrite — its two
pieces become Alt 2's method bodies verbatim).

> **DA's crux assessment:** the unifying "one mechanism" is real only as an
> *extensibility interface* (`print-method` open dispatch), NOT as a single code
> path. cljw already materialises the realize/render split as two stages
> (`deepRealize` then `printValue`); the eduction bug is a realization miss, the
> record bug a rendering default — two fixes in two stages.
> **DA ranking (non-binding):** Alt 3 (best F-002/F-009/F-011 balance for D-190's
> actual scope; its pieces survive into Alt 2 → never wasted) > Alt 2 (true
> subsystem finished form; choose only if user-extensible `print-method` is
> near-term, with `Sequential` as co-requisite) > Alt 1 (rejected: `kind`-switch
> is the F-011 ad-hoc failure mode; enlarges the rewrite).

**Main-loop decision:** Alt 3 **sharpened** — the realization discriminator is a
real `Sequential` marker protocol (not Alt 3's `kind`/Seqable heuristic, which
the oracle shows mis-handles records). This keeps the eduction fix principled
(`Sequential` → seq, JVM-faithful), commonises the latent `sequential?`
divergence onto the same marker, and stays a strict shrinking skeleton toward
the deferred Alt 2. The scope question ("is user-extensible `print-method`
near-term?") is answered No on merits, per F-002's "downgrade only on the scope
question, never on diff size".

## Consequences

- `(prn (eduction (map inc) [1 2 3]))` → `(2 3 4)`; `(sequential? (eduction …))`
  → `true`; `(prn (->Pt 1 2))` → `#Pt{:x 1, :y 2}` (ns-prefix residual deferred).
- `defprotocol` now accepts marker protocols (`(defprotocol Sequential)`),
  matching JVM. Existing ≥1-method protocols unaffected.
- One `Sequential` marker is the SSOT for both seq-print and `sequential?` — no
  second source of truth to drift.
- A future ADR can route the print sink through a real `print-method` multimethod
  reusing these three pieces as method bodies; nothing here is throwaway.

## Affected files

- `src/lang/macro_transforms.zig` — `expandDefprotocol` guard relaxation.
- `src/runtime/error/catalog.zig` — `defprotocol_form_incomplete` template.
- `src/lang/clj/clojure/core.clj` — `(defprotocol Sequential)`; extend on
  `Eduction`.
- `src/lang/primitive/core.zig` — `sequentialQ` protocol-aware arm.
- `src/runtime/print.zig` — `deepRealize` `.typed_instance` Sequential-realize
  arm; `printTypedInstance` record map-style branch.
- `test/e2e/phase14_*.sh` — RED → green print-form cases.
- `.dev/debt.md` — D-190 → Discharged.
