# 0108 — `clojure.lang.*` host-static surface tree (clojure.lang.Util)

- **Status**: Accepted
- **Date**: 2026-06-07
- **Phase**: Phase 14 (post-v0.1.0 coverage) — Convergence Campaign Stage 1.3 (library ladder)
- **Amends**: ADR-0029 (surface layout adds a third tree)
- **Tags**: phase-14, host, interop, clojure-lang, surface, ladder, F-013

## Context

The real-world pure-Clojure library ladder (Stage 1.3) finds that
data-structure libraries drop to `clojure.lang.*` runtime internals for
static helpers: `(clojure.lang.Util/hash x)` (data.finger-tree:405),
`(clojure.lang.Util/equiv …)`, `(clojure.lang.RT/count …)`, etc. A grep of
the official corpus shows ~95 `Util`/`RT` static call sites (Util/equiv 24×,
Util/isInteger 21×, Util/hash 14×, RT/map 12×, Util/hasheq 10×, Util/equals
10×, …). cljw has NO `clojure.lang.*` surface, so these error
`No namespace: 'clojure.lang.Util'`.

cljw already has the host-surface mechanism (ADR-0029): a `___HOST_EXTENSION`
with `cljw_ns` + a `TypeDescriptor` whose `method_table` maps method names to
`BuiltinFn`s. Static dispatch resolves `(Class/method …)` via
`resolveJavaSurface(head)` → `rt.types.get(head)` then
`rt.types.get("cljw." ++ head)`. A surface registered as `cljw.clojure.lang.Util`
therefore makes `(clojure.lang.Util/method …)` resolve with no resolver change.

But ADR-0029 established only TWO surface trees — `runtime/java/**`
(`cljw.java.*`) and `runtime/cljw/**` (`cljw.*`). `clojure.lang.*` is the JVM
Clojure runtime's internal namespace: neither `java.*` nor cljw-original. This
ADR adds a third tree.

## Decision

1. **A new `src/runtime/clojure/lang/` surface tree** mirrors the JVM package,
   registered under `cljw.clojure.lang.*`. First member: `Util.zig`
   (`cljw_ns = "cljw.clojure.lang.Util"`). This is the finished-form placement
   (DA Alt 2) — an honest package mirror, not the `runtime/java/lang/Util.zig`
   category-lie (DA Alt 1) where the `cljw_ns` string and the directory would
   contradict each other.

2. **Scope = the `clojure.lang.Util` class's pure public statics only**
   (F-013 definition-derived; the class is a closed, enumerable API). `RT`,
   `Numbers`, `APersistentMap` are separate definition-derived big-bang units
   (debt rows), NOT crammed in here. The Tier-D statics (`loadWithClass`,
   classloader/reflection) are excluded.

3. **Method mapping (oracle-verified 2026-06-07):**

   | Util static      | cljw impl                      | oracle parity                                                                                                                                                                         |
   |------------------|--------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
   | `equiv(a,b)`     | `=` (equal.zig)                | ✓ `(equiv 1 1.0)`→false = cljw `=` (both category-strict, F-005)                                                                                                                    |
   | `identical(a,b)` | `identical?`                   | ✓ `(identical 1 1)`→true (small-int immediates)                                                                                                                                     |
   | `compare(a,b)`   | `compare`                      | ✓ nil-least: `(compare nil 1)`→-1, `(compare nil nil)`→0                                                                                                                           |
   | `isInteger(x)`   | `integer?`                     | ✓ Long/BigInt; **F-005 divergence** on cljw-absent Short/Byte (`(short 5)` is a cljw Long → true; clj false) → AD                                                                  |
   | `hash(x)`        | cljw hash                      | **AD-009** (cljw-native hash; intra-cljw consistency only)                                                                                                                            |
   | `hasheq(x)`      | cljw hash                      | **AD-009** (same)                                                                                                                                                                     |
   | `classOf(x)`     | `class`                        | ✓ `(classOf 5)`→Long                                                                                                                                                                |
   | `equals(a,b)`    | **custom** same-type-and-value | clj `(equals 1 1N)`→false (Java `.equals`, type-sensitive); cljw `.equals`/`=` both →true, so a faithful `equals` needs an explicit same-descriptor-AND-value check, NOT a fn alias |
   | `pcequiv(a,b)`   | `=`                            | persistent-collection equiv = `=`                                                                                                                                                     |
   | `hashCombine`    | `hash.zig` Murmur3 combine     | AD-009 (intra-cljw)                                                                                                                                                                   |
   | `isPrimitive(c)` | `false`                        | cljw has no primitive Classes (F-005/ADR-0059)                                                                                                                                        |

   `equiv`'s long/double/char/boolean overloads collapse to the `Object,Object`
   form (F-005: no primitive specialization).

4. **Gate amendments (Alt 2 is incomplete without them — the zone/marker gates
   hardcode `runtime/java/*` + `runtime/cljw/*`):**
   - `scripts/zone_check.sh`: add `runtime/clojure/*` to the surface whitelist
     AND a D2 arm forbidding `runtime/clojure/* → runtime/java/* | runtime/cljw/*`
     (the three surface trees all reach the shared neutral impl, never each other).
   - `_host_api`: a `runtime/clojure/_host_api.zig` aggregator (or extend the
     single `installAll`) lists the new surface.
   - `.claude/rules/feature_name_consistency.md`: extend the scan set to
     `runtime/clojure/**` + the `Backend:` marker convention — **CARRY-OVER**
     (the auto-mode classifier blocks `.claude/rules/*` edits; surface to the
     user). Enforcement is the scripts (editable); the `.md` is doc-accuracy.

## Alternatives considered

_Devil's-advocate subagent output (fresh context), verbatim:_

> **Pre-note on a factual error in the draft brief:** the brief cited AD-006 for
> the cljw-native-hash divergence; the correct anchor is **AD-009** (AD-006 is
> `Double/parseDouble`). Corrected throughout this ADR.
>
> **Alt 1 — Smallest-diff: `Util.zig` under `runtime/java/lang/`.** Better: zero
> new wiring — drops into the existing `installAll` next to `Math.zig`;
> `cljw_ns = "cljw.clojure.lang.Util"` resolves via the existing
> `rt.types.get("cljw." ++ head)` fallback; the zone gate + feature_name gate
> already cover `runtime/java/*` for free. Breaks: category lie — `clojure.lang.*`
> is not `java.*`; a `clojure.lang.Util` file physically in `runtime/java/lang/`
> next to `java.lang.Math` is exactly the smallest-diff convenience F-002 forbids;
> the `cljw_ns` string says `clojure.lang.Util` while the directory says `java/lang`
> — self-contradictory metadata.
>
> **Alt 2 — Finished-form: new `runtime/clojure/lang/` tree + aggregator
> (RECOMMENDED).** Better: honest package mirroring; scales to the inevitable
> `clojure.lang.RT`/`Numbers`/`APersistentMap`; the cljw_ns/directory/FQCN triple
> is internally consistent. Breaks/hidden cost the brief understates: the zone gate
> and consistency gate HARDCODE `runtime/java/*` + `runtime/cljw/*` — a third tree
> is invisible to G1, so `runtime/clojure/lang/Util.zig` could import from
> `runtime/java/**` with no gate complaint, silently violating ADR-0029 D2. So Alt 2
> is incomplete unless it ALSO amends both gates to admit a third surface root (and
> decides `runtime/clojure/**` may NOT import the other surface trees). This is an
> ADR-0029 amendment, mandatory not optional. Per F-002 the size is irrelevant.
>
> **Alt 3 — Wildcard: flat FQCN-keyed host-static registry, tree-independent.**
> Better: decouples "internal runtime helper class" surfaces from directory layout;
> one registry serves Util/RT/Numbers without three directories. Breaks: a second,
> parallel dispatch mechanism competing with ADR-0029's `TypeDescriptor`/`method_table`
> — a fork in the surface model; loses the per-file `Backend:` marker + the neutral-impl
> zone discipline the file-tree gates enforce. Trades a category-lie for an un-gated
> escape hatch. Rejected.
>
> **Recommendation: Alt 2**, citing F-002 (finished-form wins; the new tree + the two
> gate amendments are the honest shape, LOC is not a constraint). Alt 1's category lie
> is the smallest-diff bias the project forbids; Alt 3 forks the dispatch model. The ADR
> must scope-in the `zone_check.sh` + `feature_name_consistency.md` amendments to
> recognize `runtime/clojure/**` as a third surface root.
>
> **Method-mapping correctness (flag-before-ship):** cljw `=` is category-gated, which
> the brief's draft mappings handle correctly for `equiv` (both category-strict → match)
> but NOT for `equals`: `Util/equals` is Java `.equals` (type-sensitive),
> `(Util/equals 1 1N)`→false, must NOT alias to cljw `=`/`.equals` (both →true) — needs a
> same-type-AND-value check, oracle-pinned. `Util/identical`→`identical?` safe for small
> ints but probe boxed Longs. `Util/isInteger` differs on cljw-absent Short/Byte (F-005) →
> AD. `Util/compare` confirm nil-least. `hashCombine` only matters intra-cljw under AD-009.
>
> **`Util/hash`/`hasheq` under AD-009: acceptable** — AD-009's contract is intra-cljw
> consistency (equal values hash equal — the HAMT key contract); libs call `Util/hash` to
> BUILD their own runtime structures, which is all they need. The one corruption vector is a
> lib shipping a precomputed JVM hash constant and asserting against it — pre-existing AD-009
> surface, does not block; add a corpus pin `(= (Util/hash :a) (hash :a))` and never claim
> cross-runtime hash stability.
>
> **Scope (F-013): one class (Util) is the correct definition-derived unit** — a real,
> enumerable JVM class with a closed public-static API. NOT "all of clojure.lang statics"
> (RT alone has ~200, mostly Tier-D) — forcing RT+APersistentMap in would be the opposite
> F-013 failure (ad-hoc "make finger-tree pass"). Land Util's complete pure set now, build
> the tree + gate amendments now (next class = pure file-add), record RT/Numbers/APersistentMap
> as separate big-bang debt rows.
>
> **Gate-amendment checklist:** `zone_check.sh` add `runtime/clojure/*` whitelist + a D2 arm
> forbidding `runtime/clojure/* → runtime/java/* | runtime/cljw/*`;
> `feature_name_consistency.md` extend the scan set + Backend-marker convention; `_host_api`
> aggregate the new tree (hand-maintained enumeration must list `Util`).

## Consequences

- `(clojure.lang.Util/method …)` resolves for the pure statics; data.finger-tree
  advances past :405. Broadly unblocks corpus libs that drop to `Util` internals.
- A third surface tree exists; future `clojure.lang.*` classes are pure file-adds
  + an aggregator line + (if a new sub-namespace) a zone whitelist row.
- `Util/hash`/`Util/hasheq` inherit AD-009 (cljw-native hash). A new AD records
  the `Util/isInteger` Short/Byte F-005 divergence. `equals` ships faithful
  (same-type-and-value), oracle-pinned in the corpus.
- The `feature_name_consistency.md` scan-set update is a tracked carry-over until
  the user lands it; the new tree carries the `Backend:` marker regardless.
