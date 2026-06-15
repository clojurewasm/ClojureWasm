# ADR-0149 — Small-ratio inline-i64 representation (canonical two-tier Ratio)

- **Status**: **Accepted** (2026-06-16, ADR-0148 campaign — ratio_sum, the lone
  far target after cycle 1). Implements the small-ratio lever the ADR-0148
  numeric-tower theme named. Devil's-advocate fork run (mandatory at depth ≥2);
  output verbatim in *Alternatives considered*.
- **Relates to**: F-004 (NaN-box slots — Ratio at Group D slot 49), F-005 (numeric
  tower: JVM-surface observable, Zig-affine internals, runtime auto-promotion),
  F-011 (behavioural equivalence vs clj), ADR-0027 (Ratio slot), ADR-0148
  (campaign), D-450. Builds on O-037/O-038 (ratio operand zero-copy + arena scratch).

## Context (the measurement)

`ratio_sum` `(reduce + (map #(/ 1 %) (range 1 51)))` ×1000 is cljw's worst
remaining perf gap (81 ms; 2.34× vs Babashka 35 ms). Decomposition: div-creation
33 ms, reduce-sum +48 ms. Each `(/ 1 x)` (x ≤ 50 — a tiny ratio `1/x`) costs
~600 ns and does **~6 heap allocations** (2 operand Managed coercions + 1 scratch
arena + 2 result BigInt allocs + 1 Ratio struct) — it is ALLOC-bound. The
harmonic accumulator's denominator only exceeds i64 after ~15 of 50 terms, so the
vast majority of intermediate ratios fit i64. Babashka pays JVM BigInteger (fast
gcd + TLAB alloc); cljw pays `std.math.big` + GPA per tiny ratio.

## Decision

Add a **canonical two-tier Ratio**: store numerator+denominator **inline as i64**
when both fit i64 in reduced form; otherwise the existing `*BigInt` pair. The
representation is **canonical** — a Ratio is small **iff** its reduced numer AND
denom both fit i64. No value has two representations. Auto-promote to big on any
i64 overflow during construction/arithmetic. Observable behaviour is unchanged
(F-005: JVM-surface, Zig-affine internals, runtime-owned promotion).

```zig
pub const Ratio = extern struct {
    header: HeapHeader,
    is_small: u8,   // invariant: 1 IFF reduced numer,denom both fit i64
    _pad: [5]u8,
    a: u64,         // small: @bitCast i64 numer ; big: *BigInt numer
    b: u64,         // small: @bitCast i64 denom ; big: *BigInt denom
};
```

Fits the existing Group D slot 49 (discriminant in the former `_pad`) — **no new
F-004 slot** consumed.

## The central design constraint (the DA's leading finding)

`equal.zig::ratioKeyEq` and the `.ratio` arm of `hash.zig::valueHash` are
**rt-free** (map-key-callable) and compare/hash the BigInt **limbs directly**,
justified by "two equal ratios have bit-identical numer+denom". A small-ratio
representation would break this — UNLESS the **canonicalization invariant** holds:

> small **iff** reduced value fits i64 ⟹ a small `1/2` and a big `1/2` **cannot
> coexist** ⟹ small-vs-big are **never equal** ⟹ `ratioKeyEq` stays rt-free:
> `if (a.is_small != b.is_small) return false;` then a same-kind compare
> (i64-vs-i64 for small, limb-vs-limb for big).

Hash parity is **free**: `big_int.managedHash` already routes an i64-fitting
Managed through `hash.hashLong(i)`, so a small ratio hashing its i64s via
`hashLong` produces the identical hash a big ratio of the same value would — and
the "never coexist" invariant means the mixed case never arises.

**This makes the invariant the linchpin**: EVERY Ratio constructor must funnel
through the canonicalizing allocator (post-reduce `toInt(i64)` collapse to small;
i64-overflow promote to big). A single constructor that forgets the collapse
silently breaks ratio map keys with no rt to repair them. Single-source-of-truth
+ a corpus pin (`(= 1/2 <big-producing-expr>)` and `(hash …)` parity) guard it.

## Implementation plan

1. **ratio.zig**: the two-tier struct; `allocFromI64Pair` small fast path (i64
   gcd via `std.math.gcd` on `@abs`, sign-normalise denom>0, **MIN_I64 →
   promote to big**); `allocFromManagedPair` post-reduce `toInt(i64)` collapse to
   small; `parts(v) RatioParts` accessor (`union(enum){small:{n,d:i64}, big:{n,d:*const BigInt}}`);
   `traceGc` = `if (is_small) return;` (small has no GC children); `compareValue`
   small/big arms; remove/restate the `@offsetOf(Ratio,"numer")==@offsetOf(BigInt,"m")`
   comptime assert (no longer always a pointer).
2. **promote.zig**: `ratioArith` small fast path — i64 cross-multiply with
   `@mulWithOverflow`/`@addWithOverflow`; **any overflow bit → fall back to the
   Managed path** (a naive `n1*d2+n2*d1` is a silent wrong-answer bug); `partsOf`
   handles small (no clone, like O-037); the BigDecimal→Ratio arm funnels through
   the canonical allocator.
3. **equal.zig / hash.zig**: `ratioKeyEq` + `.ratio` hash arm branch on
   `is_small` (i64 compare/`hashLong` for small) — staying rt-free per the
   invariant.
4. **print.zig**: small arm reads i64s directly (no BigInt round-trip).
5. **Tests**: unit (small/big/collapse/promote/MIN_I64/overflow-cross-mul) +
   diff oracle + corpus pins for cross-rep `=`/`hash`/`compare` + `clj_diff_sweep`.

## Edge cases (must-handle — naive impl bugs)

- **i64 cross-multiply overflow** even when operands fit (`numer·denom` can
  exceed i64) → `@mulWithOverflow` guard, promote on overflow.
- **MIN_I64 negation / `@abs`** overflow in sign-normalise + gcd → promote to big
  if either limb is MIN_I64 (Zig `std.math.gcd` is unsigned; `@abs(MIN_I64)`
  overflows).
- **Collapse on reduce**: a big-operand operation reducing to a small value MUST
  emit small (else `=` breaks); a small operation overflowing MUST emit big.

## Expected outcome

The `(/ 1 x)` div path drops from ~6 allocs to ~1 (the Ratio struct) + i64 gcd
(~10× on the 33 ms div part); the early small-accumulator `+` terms go i64. Target:
ratio_sum 81 → ~45-55 ms (toward Babashka 35; the late bignum terms stay big).
Broad win for all small-rational arithmetic.

## Consequences

- The canonicalization invariant is load-bearing for correctness (not just perf):
  it is what keeps the rt-free map-key path valid. A debt row + corpus pin guard it.
- Concurrency (Gap-area I): the small path is allocation-free and reads-only — no
  new shared mutable state (unlike the DA's Alt 3 intern table, rejected).
- F-004 slot budget unaffected (reuses slot 49).

## Alternatives considered (Devil's-advocate fork, verbatim)

**LEADING FINDING — no alternative violates an F-NNN.** All three shapes stay
within F-004 (existing Group D slot 49 has room for a flag/union; no new slot
needed) and F-005 (internal small→BigInt auto-promotion is explicitly endorsed).
The hard constraints are not the F-NNNs — they are two already-shipped, rt-free,
field-bit-comparing invariants in `equal.zig` and `hash.zig` that any naive
implementation will silently break.

**The under-stated risk (all 3 shapes).** `equal.zig::ratioKeyEq` and the
`.ratio` arm of `valueHash` are rt-free and compare/hash the `numer.m`/`denom.m`
limbs directly ("two equal ratios have bit-identical numer+denom"). A small-ratio
rep destroys that: a small `1/2` and a heap-BigInt `1/2` are value-equal but
physically different. Either (a) these gain an `rt` param (ripples through every
rt-free map-key call site) or (b) keep a guaranteed canonical form so the field
compare still holds. **(b) is mandatory** — *"a small ratio reduced from a big
operation MUST collapse to small, and a big ratio MUST never be storable when it
fits i64, or `=`/`hash` break for map keys with no rt to fix it up."*

**ALT 1 — smallest-diff: tagged union, accessors lazily materialize a BigInt.**
`kind` byte in `_pad`; `allocFromI64Pair` writes i64s, zero alloc;
`asNumer`/`asDenom` keep `*const BigInt` but lazily allocate+cache on first call.
*Better*: smallest ripple (`ratioArith`/`print`/`compareValue` unchanged). *Risks
— a trap*: the `*const BigInt` accessor FORCES a BigInt to exist → the first
arithmetic op (`partsOf` per accumulate) re-allocates → **alloc win evaporates**.
Caching mutates behind `*const` + needs a conditionally-present GC child →
`traceGc` branches on `kind` AND cache-state (a data race for Gap-area I).
`traceGc` marking i64-as-pointer for small = heap corruption if the branch is
missed. `ratioKeyEq`/`valueHash` still read `.numer.m` → break; the union ADMITS
overlap (same value, two forms) — the worst form of the canonicalization problem.
Slot 49, no new slot. *Verdict*: deceptively small, most bug-prone.

**ALT 2 — finished-form-clean: canonical two-tier, accessors return value-typed
`RatioParts`.** `is_small` discriminant; **invariant: small iff reduced numer+
denom both fit i64**. `allocFromManagedPair` checks `toInt(i64)` after reduction
→ a big-operand reduction landing on `3/4` collapses to small; a small op
overflowing promotes. **No value has two representations** → `ratioKeyEq` =
`if a.is_small != b.is_small return false` then same-kind compare, still rt-free;
small-vs-big never equal (a big ratio whose value fit i64 would be small by
invariant). Hash: small via `hashLong` on the i64s, which **already matches**
`managedHash`'s i64 path → cross-rep hash parity for free, mixed case never
arises. `parts(v) RatioParts` union accessor; `ratioArith` i64 fast path with
`@mulWithOverflow`/`@addWithOverflow` → Managed fallback on overflow; `print`
reads i64s. *Better*: the invariant makes the rt-free key path correct BY
CONSTRUCTION; delivers the alloc win (no `*const BigInt` materialization); the
small path is complete (arith/print/compare/hash/eq native i64); `traceGc` is
`if (is_small) return;` with no cache ambiguity. *Risks (each test-pinnable)*:
i64 cross-multiply overflows even when operands fit (`@mulWithOverflow` mandatory);
MIN_I64 negation in sign-normalise + `std.math.gcd` unsigned `@abs(MIN_I64)`
overflow → promote; cross-rep equality depends entirely on the invariant holding
→ EVERY constructor must funnel through the canonicalizing allocator (incl. the
BigDecimal→Ratio path) — single-point-of-truth + corpus test; `extern struct`
@bitCast → the `@offsetOf(Ratio,"numer")==@offsetOf(BigInt,"m")` assert becomes
wrong, remove/restate; wider diff (ratio/promote/equal/hash/print) — NOT a reason
to prefer Alt 1 (Cycle-budget-defer smell). Slot 49, no new slot. *Verdict*: the
finished form; the only shape where the rt-free key invariant survives by
construction.

**ALT 3 — wildcard: keep the representation; make the ALLOCATOR cheap (per-Runtime
small-ratio intern cache + thread-local Managed scratch pool).** Ratio struct
unchanged. (i) Intern table keyed by `(i64 numer, i64 denom)` → cached `Value`
(the harmonic sum produces the same `1/x` every one of the 1000 outer iters —
identical values, so `(/ 1 x)` becomes a lookup after first occurrence); (ii)
reusable per-Runtime Managed scratch arena for `ratioArith`'s reduce.
*Better*: ZERO representational change → `equal`/`hash`/`traceGc`/`print`/asserts/
slot untouched, none of the rt-free-key landmines touched; exploits value
recurrence across the ×1000 loop (runs the i64 gcd 50× total vs Alt 2's 50×1000);
can stack on Alt 2 later. *Risks*: the intern table is a GC ROOT surface (cached
Values must be roots or dangle — a new root slot per `.dev/gc_rooting.md`; a moving
GC must update them); cache invalidation / unbounded growth (needs a cap or it
leaks); it's a BENCHMARK-shaped fix not a representation fix — a distinct-ratio
workload (continued-fraction expansion) gets only the scratch-pool win; per-Runtime
mutable table = a Gap-area-I data race. Slot: no struct change. *Verdict*: clever,
only shape with zero rt-free-key risk, but solves a narrower problem and trades
representation landmines for a GC-rooting landmine.

**Recommendation: Adopt Alt 2 (canonical two-tier).** The only shape where the
already-shipped rt-free `=`/`hash` map-key invariant survives by construction (via
"small iff fits i64 in reduced form → small-vs-big never equal"); delivers the
alloc win without Alt 1's `*const BigInt` materialization; its risks are concrete
and test-pinnable, not architectural. Larger diff is not a reason to fall back
(Cycle-budget-defer smell). Fold in Alt 3's scratch-arena reuse as a follow-on
micro-opt only if profiling after Alt 2 still shows the reduce step hot.

## Affected files

- `src/runtime/numeric/ratio.zig` (the two-tier struct + canonical constructors +
  `parts` + traceGc/compareValue), `src/runtime/numeric/promote.zig` (`ratioArith`
  i64 fast path + `partsOf` small + BigDecimal arm), `src/runtime/equal.zig`
  (`ratioKeyEq`), `src/runtime/hash.zig` (`.ratio` arm), `src/runtime/print.zig`
  (small arm). `.dev/debt.yaml` (canonicalization-invariant pin row),
  `.dev/optimizations.md` (the O-NNN), `test/diff/clj_corpus/` (cross-rep pin).
