# ADR-0077 — BigDecimal scale-independent map key via a cached normalized form

**Status**: Proposed → Accepted (2026-06-03, clj-parity campaign C2 / D-205)

## Context

ADR-0076 §9.2.P clj-parity campaign unit **C2 (D-205)**: BigDecimal cannot be a
map key / set element. `(get {1.5M :v} 1.5M)` → cljw nil (clj `:v`);
`(contains? {1.5M :v} 1.5M)` → cljw false (clj true). BigInt and Ratio were
fixed earlier (2026-06-02) by adding numeric arms to the **rt-free**
`equal.zig::keyEqValue`; BigDecimal was explicitly punted because value-equality
across different scales needs scale alignment (multiply an unscaled BigInt by
10^Δscale = allocation), which a rt-free function cannot do.

Two functions block BigDecimal keys, BOTH rt-free (they run deep in the HAMT
lookup hot path — D-151 invariant: the key path must not require an allocator):

- `keyEqValue` `.decimal` arm — falls through (rt-free scale alignment impossible).
- `valueHash` `.big_decimal` arm — hashes `(unscaled, scale)` directly, so
  `1.5M`=(15,1) and `1.50M`=(150,2) land in different HAMT buckets.

clj semantics (oracle-verified): the BigDecimal key/hash is **scale-independent**
(stripTrailingZeros — `1.5M`/`1.50M`/`12000M`/`12000.00M` collide), `=` is
NUMERIC (`compareTo==0`), and PRINT **preserves scale** (`(pr-str 1.50M)` →
"1.50M"). So the value has two projections: scale-dependent (print / arithmetic
result-scale / `.scale` / `.precision`) and scale-independent (key / hash / `=`).

The sibling heap numerics work rt-free because they are **canonical at
construction**: Ratio is gcd-reduced, so equal ⇒ identical fields ⇒ a direct
rt-free field compare. BigDecimal lacks that property — and, unlike Ratio, it
*cannot* simply adopt it, because scale is JVM-observable (java.math.BigDecimal
itself stores scale non-canonically; `1.50M` keeps scale 2).

## Decision

Add a **cached normalized (stripped-trailing-zeros) projection** to the
BigDecimal heap struct, computed once at construction (where `rt` exists):

```
pub const BigDecimal = extern struct {
    header: HeapHeader,
    _pad: [6]u8,
    unscaled: *BigInt,      // AUTHORITATIVE value (JVM BigDecimal): print / arithmetic / .scale
    scale: i32,
    norm_scale: i32,        // the stripped scale  ┐ the Clojure scale-independent
    norm_unscaled: *BigInt, // the stripped unscaled┘ key/hash projection (cached)
};
```

- **Construction** (`allocFromManagedScale`) strips trailing zeros
  (`while unscaled≠0 and unscaled%10==0: unscaled/=10, scale-=1`; zero → (0,0))
  and stores the result as `(norm_unscaled, norm_scale)`. The original
  `(unscaled, scale)` is left untouched — it remains the authoritative value for
  print, arithmetic result-scale, and any scale accessor.
- **`keyEqValue` `.decimal` arm**: `norm_scale_a == norm_scale_b &&
  norm_unscaled_a.eql(norm_unscaled_b)` — rt-free (BigInt const compare, no
  allocation), like the Ratio arm.
- **`valueHash` `.big_decimal` arm**: hash `(norm_unscaled, norm_scale)`, so
  `1.5M`/`1.50M` collide in the same bucket (scale-independent, matching clj).
- **`traceGc`** marks `norm_unscaled` too (it is GC-managed).
- **Print / arithmetic / `compareValue` unchanged** — they read the
  authoritative `(unscaled, scale)`, so the verified scale-faithful behaviour
  (`(pr-str 1.50M)`→"1.50M", `(+ 1.50M 0.5M)`→"2.00M") is untouched (F-011).

This mirrors the real two-layer model: java.math.BigDecimal keeps scale
authoritative; Clojure's hasheq/`=` derives a stripped view. cljw caches that
derived view because it cannot recompute it on the rt-free hot path (the same
"cache an expensive-to-derive key projection" pattern as a cached hashCode).

## Consequences

- `(get {1.5M :v} 1.5M)`/`(get {1.5M :v} 1.50M)`/`(contains? #{1.5M} 1.50M)` →
  match clj. `(hash 1.5M)` == `(hash 1.50M)` (scale-independent).
- +1 pointer (`norm_unscaled`) +1 i32 (`norm_scale`) per BigDecimal; a strip
  loop + one extra BigInt alloc at construction; one extra GC mark edge. Paid
  at construction (cold), never on the rt-free key lookup (hot).
- Closes D-205 (the BigDecimal remainder; BigInt/Ratio already done). Leaves a
  corpus line. Next campaign unit: C3 = D-207.

## Affected files

- `src/runtime/numeric/big_decimal.zig` (struct + normalize-at-construction +
  traceGc + accessors + layout test).
- `src/runtime/equal.zig` (keyEqValue `.decimal` arm + valueHash `.big_decimal`
  arm).
- `test/diff/clj_corpus/bigdecimal_key.txt` (new corpus, clj-verified).

## Alternatives considered

(Devil's-advocate subagent, fresh context, per CLAUDE.md depth-≥2 mandate. The
subagent RECOMMENDED Alt 2; the main loop chose Option A — rationale below the
alternatives. Within the F-005 envelope; cycle/LOC is not a constraint.)

### Alt 1 — Smallest-diff: precomputed scale-independent hash (u32) + rt-free streaming digit compare

Add only `norm_hash: u32` (fits the existing `_pad2[4]` → zero net struct
growth); `valueHash` returns it; `keyEqValue` does an rt-free streaming
digit-aligned compare of the two unscaled values across the 10^Δscale shift.

**Better:** smallest struct (no second GC pointer, `traceGc` untouched); hot
`valueHash` is a single field load.

**Breaks/risks:** the streaming compare is the load-bearing novelty and is hard
to get right rt-free — base-10 scaling does not map to base-2^64 limb shifts, so
it degrades to schoolbook digit extraction (repeated divmod 10) which may itself
need scratch space; if it overflows a fixed buffer it reintroduces the allocator
dependency it was meant to avoid. A bug here is a *silent wrong-bucket /
wrong-equality* in the HAMT — the worst failure class. Concentrates all
difficulty in the one allocator-free corner. Viable fallback only if its
rt-free-ness is proven against a fixed scratch buffer with a documented
overflow-to-error path.

### Alt 2 — Finished-form-clean (DA-RECOMMENDED): normalize the stored form + a separate `print_scale`

Make the *stored* `(unscaled, scale)` the canonical stripped form (like Ratio);
add `print_scale: i32` recording the display scale; print re-pads. Then
`keyEqValue`/`valueHash` need **no** decimal-specific arm — the generic
canonical-numeric pattern works, matching the BigInt/Ratio sibling invariant
("equal ⇒ identical fields").

**Better:** the truest finished-form *if* BigDecimal were naturally canonical —
no shadow fields, no decimal-specific equal/hash arm, +1 i32 and no second GC
pointer, uniform with the other heap numerics (F-011).

**Breaks/risks (the DA flagged these):** the **largest blast radius** and
F-005-observable. Arithmetic result-scale is JVM-observable: `(+ 1.50M 0.5M)` →
`2.00M` (scale = max of operand scales). `alignedCombine` computes
`result_scale = @max(ad.scale, bd.scale)`; if `scale` is canonical (stripped),
`1.50M` stores scale 1 and the max-rule breaks scale-preservation. So ALL
arithmetic (`allocAdd/Sub/Mul/allocQuotient`/`alignScales`), print, and any
scale/`precision` accessor must migrate to `print_scale`, and `.precision`
depends on the *unstripped* magnitude. A partial migration = a silent F-005
violation (a canonical value printed without its trailing zeros). The DA's own
fallback note concedes this subtlety.

### Alt 3 — Wildcard: intern/canonicalize BigDecimals via an rt-side dedup table

Construction returns the same heap pointer for numerically-equal BigDecimals;
the existing `@intFromEnum(a)==@intFromEnum(b)` identity short-circuit then
handles keys for free.

**Better:** cleanest hot path (zero new equal/hash logic).

**Breaks/risks — FATAL under F-005:** interning by numeric value collapses
`1.5M` and `1.50M` to one pointer → only one scale survives → `(pr-str 1.50M)`
can no longer be "1.50M". Interning by `(unscaled, scale)` keeps print but makes
them distinct pointers again (identity short-circuit does not fire cross-scale)
→ back to needing a real arm. Also a global mutable GC-aware table on the hot
construction path. Dead end. Rejected.

(Brief (e) "thread rt into the HAMT key path" — rejected against the D-151
rt-free invariant: a depth-4 change to the central data-structure contract to
serve one numeric type.)

### Decision vs the alternatives — why Option A over the DA's Alt 2

The DA's Alt 2 case rests on "BigDecimal should be canonical at construction
like Ratio." **That analogy is the flaw.** Ratio's reduced form *is* its value
— there is no display variant. BigDecimal's scale is **JVM-observable and
authoritative**: java.math.BigDecimal stores scale non-canonically *on purpose*,
because print, arithmetic result-scale, `.scale`, and `.precision` all depend on
the unstripped form. Alt 2 makes the stored scale non-authoritative and forces
every one of those F-005-observable behaviours to be re-derived on `print_scale`
— with the silent-divergence risk the DA itself enumerated.

Option A keeps the authoritative `(unscaled, scale)` exactly as java.math.BigDecimal
holds it (so the verified arithmetic/print is untouched — F-011 behavioural
equivalence) and adds the stripped projection as the **cached Clojure-key view**.
The "shadow field" the DA names a smell is the faithful modelling of the genuine
two-layer reality (JVM scale-authoritative + Clojure strip-for-key); caching a
hot-path-too-expensive derived key is a standard pattern, not a smell. The
choice is on finished-form-fidelity grounds, NOT cycle/LOC (Option A is in fact
*more* localised, but that is incidental — the deciding factor is that Alt 2
fights the type's JVM-observable nature).

## Revision history

- 2026-06-03 created (Accepted): clj-parity C2 / D-205. Option A (cached
  normalized projection) chosen over the DA-recommended Alt 2 (canonical storage
  + print_scale) on finished-form-fidelity grounds — BigDecimal scale is
  JVM-authoritative, unlike Ratio.
