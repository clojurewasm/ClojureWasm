# ADR-0072 — Protocol extension over native / java classes (native-descriptor identity)

- Status: Accepted
- Date: 2026-06-02
- Supersedes: none
- Refs: D-203 (this decision's debt entry), D-202 gap (2) (the
  superseded plan), ADR-0036 (dual-backend parity), ADR-0059
  (one-canonical-descriptor-ref invariant), F-002 / F-005 / F-009.

> Landed 2026-06-02 exactly as the Decision below specifies:
> `class_name.nativeTagFor` accessor + the `analyzeSymbol`
> `symbol_unresolved` fallback arm. 8 e2e cases
> (`test/e2e/phase7_extend_native_class.sh`, incl. `--compare`
> dual-backend) + 2 unit tests on `nativeTagFor`. The SSOT
> consolidation in the Deferred section remains its own cycle (tracked
> in D-203).

## Context

cljw cannot `(extend-type java.lang.Long P …)` / `(extend-type String P
…)` — extending a protocol to a built-in / java class. The macro
`expandExtendType` emits `(rt/__extend-type! <target> P impls)`;
`__extend-type!` (`lang/primitive/protocol.zig:163`) requires `<target>`
to evaluate to a `.type_descriptor` Value. A cljw `deftype`/`defrecord`
Name works (it is `def`'d to a TypeDescriptorRef); a class symbol like
`String` or `java.lang.Long` fails to resolve as a symbol.

### Root cause (the D-202 gap (2) plan was wrong)

D-202's barrier proposed "resolve the target via
`special_forms.resolveJavaSurface`". That is **incorrect**. Protocol
dispatch maps a primitive receiver (integer `5`, string `"x"`) to a
descriptor via `rt.nativeDescriptor(receiver.tag())`
(`runtime/runtime.zig`) — a per-Tag cached descriptor with fqcn
`"Long"`/`"String"` — which is a **different object** from any
`cljw.java.lang.Long` entry in `rt.types` that `resolveJavaSurface`
returns. So for `(q 5)` to dispatch to the impl, the impl MUST be
registered on `rt.nativeDescriptor(.integer)` — the descriptor the
dispatch path actually resolves — not on a `rt.types` surface
descriptor. `src/runtime/class_name.zig` already carries the needed
relation: `NATIVE_ENTRIES` (name→Tag) + `FQCN_MAP` (FQCN→simple name).
`type_descriptor.makeTypeDescriptorRef(rt, td)` mints the canonical
boxed Value (ADR-0059).

## Decision

Resolve a known **native** class symbol to its native TypeDescriptor in
the analyzer's `analyzeSymbol` (`eval/analyzer/analyzer.zig:477`), on
the `symbol_unresolved` fallback — i.e. **after** local + Var
resolution, so a user `(def String …)` / `(deftype String …)` shadows
the class name:

```
const v_ptr = ns.resolve(sym.name) orelse {
    if (sym.ns == null) if (class_name.nativeTagFor(sym.name)) |tag| {
        const td = try env.rt.nativeDescriptor(tag);
        return makeConstant(arena, try type_descriptor.makeTypeDescriptorRef(env.rt, td), form);
    }
    return error_catalog.raise(.symbol_unresolved, ...);
};
```

- Add `class_name.nativeTagFor(name) ?Tag` — an accessor over the
  **existing** `NATIVE_ENTRIES` (normalising via `FQCN_MAP` first). NOT
  a new table.
- Only `NATIVE_ENTRIES` exact-tag classes resolve
  (String/Long/Double/Boolean/Character/Keyword/Symbol/Persistent\*/Pattern).
  Interface-shaped names (Number/IFn/IPersistentMap) do **not** resolve
  (no single tag) — document as a divergence; ideally raise a hint
  error suggesting the concrete types.

This makes bare `String`/`Long`/`java.lang.Long` evaluate to the same
descriptor `(class 5)` already returns (clj-faithful: a class symbol is
a value) — a coherence requirement, not just a feature: a narrow
target-position-only resolution would leave `(class 5)` printing `Long`
while `Long` alone throws. One locus covers extend-type /
extend-protocol / `lowerDefType` extend sections / the lower-level
`extend` fn / bare-class-as-value.

### Deferred (NOT bundled)

The DA recommended also consolidating the name↔Tag relation
(`runtime.zig::nativeFqcnFor` Tag→name vs `class_name.zig::NATIVE_ENTRIES`
name→Tag, which have already drifted: nativeFqcnFor knows
BigInt/Ratio/BigDecimal, NATIVE_ENTRIES does not) into one SSOT. This
is **declined for this cycle** — not on cost grounds (F-002), but
because consolidation would broaden `instance?`/`class` coverage to
BigInt/Ratio/BigDecimal, a separable finished-form decision that risks
an unrelated surface. Tracked in D-203 as its own cycle.

## Consequences

- `(extend-type Long P …)` / `(extend-type String P …)` work; the impl
  lands where dispatch finds it. Verify via e2e + dual-backend
  `--compare`.
- Bare native-class symbols become values (= `(class x)`); clj-faithful.
- `(deftype String …)` shadowing is correct by placement (after Var
  resolution).
- Interface names still raise `symbol_unresolved` (acceptable; document).

## Affected files

- `src/runtime/class_name.zig` (+ `nativeTagFor`).
- `src/eval/analyzer/analyzer.zig` (`analyzeSymbol` fallback arm).
- e2e `test/e2e/phase7_extend_native_class.sh` (new) + a diff_test case.

## Alternatives considered

(Verbatim from the mandatory Devil's-advocate subagent, fresh context,
F-NNN envelope. Recommendation: the Decision above = the DA's "Alt 2"
locus, minus the bundled consolidation which D-203 defers.)

### Alternative 1 — Smallest-diff: resolve in the macro via `__native-type`

Leave `analyzeSymbol`/`__extend-type!`/class-as-value untouched. In
`expandExtendType` (+ extend-protocol / lowerDefType callers), if the
target is a bare symbol whose normalised name hits
`class_name.nativeTagFor`, rewrite the target to `(rt/__native-type
:<tag>)` (the existing primitive that already mints
`rt.nativeDescriptor(tag)`). Narrowest blast radius (cannot leak into
`(class …)`), zero new dispatch object, covers extend-protocol /
lowerDefType for free (they re-enter expandExtendType). BUT it **cannot
honor shadowing** (macro runs before analysis, no Var visibility, so it
must unconditionally steal `String` from a user `(deftype String …)`),
and bare `Long`-as-value still fails. Smallest-diff-bias trap: trades
away shadowing correctness + class-as-value.

### Alternative 2 — Finished-form (RECOMMENDED): resolve in analyzeSymbol + consolidate name↔Tag SSOT

The Decision's locus, plus consolidating the three faces of the
name↔Tag relation (nativeFqcnFor, NATIVE_ENTRIES, the new nativeTagFor)
into one bidirectional SSOT in class_name.zig (Layer 0), with
nativeFqcnFor deriving from it. Placing resolution after Var resolution
is the only locus that simultaneously honors `(deftype String …)`
shadowing without macro-time namespace visibility, covers all entry
surfaces through one path, and makes `Long` agree with the descriptor
`(class 5)` already produces (so the "broad" behavior is a coherence
requirement, not a risk — a narrow resolution would make `(class 5)`
print `Long` yet `Long` alone throw). Costs a bigger diff (touches
class_name.zig + runtime.zig + analyzer.zig); F-002 says recommend it
anyway. One under-specified point in the draft: the SSOT for the
relation, where three faces already drifted (nativeFqcnFor knows
BigInt/Ratio, NATIVE_ENTRIES does not) — fix the consolidation now even
though it enlarges the diff; F-009 puts the relation in neutral Layer-0
class_name.zig with the analyzer as a pure consumer. Interface-shaped
names (Number/IFn) intentionally do not resolve — make that a
documented, tested divergence with a precise error, not silent.

> **Main-loop deviation from the DA recommendation**: the Decision
> adopts Alt 2's *locus* but **defers the SSOT consolidation** to D-203.
> Not on cycle/diff grounds (that would be the Cycle-budget defer smell)
> — the consolidation would *broaden* `instance?`/`class` coverage to
> BigInt/Ratio/BigDecimal (which NATIVE_ENTRIES lacks), which is a
> separable finished-form decision with its own surface implications.
> Bundling it into a protocol-extension feature risks an unrelated
> surface. The feature's own finished form (shadow-correct, class-as-
> value, all-loci, native-descriptor identity) is fully delivered
> without the consolidation.

### Alternative 3 — Wildcard: `__extend-type!` accepts any target shape (Path-A unification)

Relax `extendType`'s `args[0].tag() == .type_descriptor` requirement;
accept a quoted symbol/string and resolve native-class names in the
primitive (Layer 2, widest legal reach), with the macro auto-quoting
the target like `instance?` already does. Unifies on the `instance?`
"Path A" idiom (one mental model: class symbols auto-quoted + resolved
primitive-side) and sidesteps the "bare-Long-as-value too broad?"
debate entirely. BUT loses class-as-value (same gap as Alt 1, relocated
to the primitive); re-opens a loud-rejection contract the codebase
deliberately closed (`extendType` rejecting non-descriptor args); and
the auto-quote decision for lowerDefType's *user-type* targets needs
namespace visibility the macro lacks (reintroducing Alt 1's
macro-can't-see-Vars discrimination problem) — so `(deftype String …)`
+ `(extend-type String …)` would resolve String as a native class,
ignoring the user deftype. Architecturally interesting (Path-A
unification) but forfeits two finished-form properties the Decision
holds.
