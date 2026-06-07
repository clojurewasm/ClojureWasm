# Real-world library compatibility ladder

Ranked by pure-Clojure degree (1 = zero host interop, easiest/earliest;
5 = threads / java.io / reflection-heavy). See `README.md` for the method,
the load mechanism (`-cp` manual classpath), and the status vocabulary.

Probed on cljw built from `cw-from-scratch` (2026-06-06). Rows marked
**loads / partial / fails** were actually `require`'d; rows marked
**not-probed** are static source inspection only. As of Stage 1.2,
deps.edn resolution works (`:paths`/`:local/root`/`:aliases`/`:git/url`),
so rungs are now probed via real **deps.edn git coordinates**, not just
`-cp` (rung 4 below was the first such probe).

| rank | lib                        | version       | pure-degree | status     | first-blocking-gap                                                                                                                                                                                                                                                                                                                                                                                                                                 |
|------|----------------------------|---------------|-------------|------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1    | medley                     | master        | 1           | loads      | none — find-first/dissoc-in/map-keys/index-by/deep-merge/uuid?/abs all correct                                                                                                                                                                                                                                                                                                                                                                    |
| 2    | clojure.math.combinatorics | master        | 1           | loads      | none — permutations correct                                                                                                                                                                                                                                                                                                                                                                                                                       |
| 3    | clojure.tools.cli          | master (cljc) | 1           | loads      | none — parse-opts returns correct :options map                                                                                                                                                                                                                                                                                                                                                                                                    |
| 4    | clojure.data.priority-map  | master        | 1           | loads      | FULLY FUNCTIONAL — `(priority-map :a 3 :b 1 :c 2)` → peek=[:b 1] (lowest), count=3, keys=(:b :c :a), vals=(1 2 3). Drove the whole deftype host-interface stack: clojure.lang.* family (D-275/D-279/D-280), java.util.Map/Iterable host_inert (D-281/ADR-0103), clojure.core.protocols (D-282), clj-name `.method` dot-calls (D-283), `(MapEntry. …)`→2-vec (D-284), keys/vals seq-derivation (D-285).                                         |
| 4b   | flatland.ordered (amalloy) | master        | 1           | fails      | Re-probed 2026-06-07 after D-287 (Java arrays) landed: `aset` (set.clj:84) now resolves; advances to set.clj:95 `IEditableCollection` — a clojure.lang deftype-supertype (host-interface, D-286b family). Earlier: D-286a cleared all bare deftype-supertype names; D-287 cleared the Java-array backing store.                                                                                                                                   |
| 5    | clojure.data.generators    | master        | 2           | loads      | FULLY FUNCTIONAL 2026-06-07 - loads + bit-for-bit seeded parity with clj: `(binding [gen/*rnd* (java.util.Random. 42)] [(gen/long)(gen/long)(gen/boolean)(gen/double)])` => [-5025562857975149833 -5843495416241995736 false 0.9420735430282128] (identical to clj). Drove D-289 (java.util.Random LCG), D-295 (Short/Byte statics), D-296 (syntax-quote machinery clojure.core-qualified). The test.check foundation is now LIVE on cljw.         |
| 6    | clojure.tools.reader       | master        | 2           | parked     | PARKED 2026-06-07 (Step-0.6 finding): cleared D-288 (mutable field), D-287 (arrays), D-291 (Closeable), D-292 (multi-protocol extend-type) - all general wins. Remaining chain is DEAD interop in cljw: extend-type on java.io.PushbackReader/Reader/InputStream (D-293) + bare `extend` map-form; cljw uses its OWN reader path so these extensions can never dispatch. Loading them is low-value. Resume if a LIVE host-target consumer appears. |
| 7    | clj-commons/clj-yaml-pure  | n/a           | 2           | not-probed | (placeholder: pure EDN/string-shaped; verify a real pure-clj yaml exists)                                                                                                                                                                                                                                                                                                                                                                          |
| 8    | cuerdas                    | master (cljc) | 3           | partial    | NEEDS-ROW: java.util.regex.Pattern static interop (Pattern/quote) — capitalize fails                                                                                                                                                                                                                                                                                                                                                              |
| 9    | clojure.data.xml           | master        | 3           | not-probed | NEEDS-ROW: javax.xml.stream (StAX) reader/writer interop                                                                                                                                                                                                                                                                                                                                                                                           |
| 10   | instaparse                 | master (cljc) | 4           | not-probed | NEEDS-ROW: java.io.FileNotFoundException catch + file slurp in core                                                                                                                                                                                                                                                                                                                                                                                |
| 11   | clojure.data.json          | master        | 4           | not-probed | NEEDS-ROW: java.io PrintWriter/PushbackReader/StringWriter + clojure.pprint require                                                                                                                                                                                                                                                                                                                                                                |
| 12   | cheshire                   | 5.x           | 5           | not-probed | NEEDS-ROW: Jackson (com.fasterxml.jackson) JNI/Java class — not pure Clojure                                                                                                                                                                                                                                                                                                                                                                      |
| 13   | clj-time                   | n/a           | 5           | not-probed | not pure (joda-time Java dep) — out of pure ladder, kept as a boundary marker                                                                                                                                                                                                                                                                                                                                                                     |
| 14   | core.async                 | master        | 5           | not-probed | NEEDS-ROW: threads / executors / go-macro state machine (Campaign Stage 1.7 Phase B)                                                                                                                                                                                                                                                                                                                                                               |
| 15   | next.jdbc                  | n/a           | 5           | not-probed | not pure (java.sql.* JDBC) — out of pure ladder, boundary marker                                                                                                                                                                                                                                                                                                                                                                                  |

## Notes per rung

- **Rungs 1–3 (loads, degree 1):** the ladder head is green. `medley`,
  `math.combinatorics`, and `tools.cli` all `require` and run correctly on
  cljw today with only a manual classpath. This is the concrete evidence that
  cljw's `clojure.core` surface (protocols, records, transducers, sorted
  collections, metadata, regex, reduce-kv) covers a real pure-Clojure library
  end to end.
- **Rung 8 (cuerdas, partial → Pattern/quote landed):** loads after its
  `cuerdas.regexp` dependency is laid out, but `capitalize` (and other fns) hit
  `(java.util.regex.Pattern/quote ...)` — a static Java-class method call cljw
  did not resolve. This was the first *real* feature gap the ladder found, as
  opposed to a missing-resolver blocker. **`Pattern/quote` is now wired**
  (Pattern.zig static surface; the regex engine already honored `\Q…\E`),
  clj-faithful bit-for-bit (corpus `regex_pattern.txt`). Re-probe cuerdas when
  it is re-fetched to find the next blocker (likely more Pattern statics:
  `compile` / `matches` / flag constants).
- **Rungs 5, 9–14 (NEEDS-ROW):** static inspection shows each touches a Java
  surface cljw does not yet provide (seeded RNG, StAX XML, `java.io`
  reader/writer, Jackson, threads). These are the honest next gaps; the main
  loop converts each `NEEDS-ROW:` into a `debt.yaml` row classified against
  the Java-tier SSOT.
- **Rungs 13, 15 (not pure):** kept as boundary markers so the ladder makes
  explicit *where* the pure-Clojure frontier ends — they will not load without
  the underlying Java library, regardless of cljw progress.

- **test.check** (probed 2026-06-07 via -cp, data.generators now FULLY FUNCTIONAL): advanced past random.clj:106 hex-literal (fixed D-297, hex>i64 -> BigInt) to random.clj:178 `(proxy [ThreadLocal] …)` -> D-298 (proxy unrecognised; JVM-class proxy = Tier D). PARKED (proxy depth vs partial benefit; seeded paths might work with proxy-recognition level (a)).

- **Pure deftype/algo libs probed (2026-06-07 via -cp):**
  - **clojure.data.finger-tree** — `(extend-type nil …)` (nil-punning protocol
    extension) was unsupported (`__extend-type!: expected type_descriptor, got
    nil`). **Fixed** (extend-type + extend-protocol now accept a nil target →
    the per-Tag nil descriptor; clj-faithful, e2e `phase14_extend_type_nil`).
    Advanced :56 → :138 — `(defdigit a)` macro hit two deftype-method-lowering
    gaps, both **now fixed** (clj-faithful, e2e `phase14_deftype_method_lowering`):
    (a) syntax-quote-qualified method params (`user/_` from a bare `_` inside a
    backtick — clj's deftype/reify strip the ns; raw fn* still rejects, parity
    kept); (b) empty method bodies `(m [_])` → nil. Advanced :138 → :405 —
    `clojure.lang.Util/…` static interop. **Now wired** (ADR-0108 — new
    `runtime/clojure/lang/` host-surface tree; `clojure.lang.Util` ships 10 pure
    statics, oracle-verified, corpus `clojure_lang_util.txt`; `Util/classOf`
    deferred D-303). Advanced :405 → :519 — `Counted` (a `clojure.lang.*`
    interface marker, host_interfaces.yaml territory; next finger-tree blocker,
    parked). The `clojure.lang.Util` surface broadly unblocks the ~95 corpus
    `Util` call sites; `RT`/`Numbers`/`APersistentMap` are separate units.
  - **clojure.algo.generic** — `(derive Object root-type)`: bare `Object` as a
    class VALUE to `derive` is unresolved (host-class-value family, D-293).
  - **clojure.data.avl** — `(APersistentMap/mapHash …)` + `^AtomicReference`/
    `^Comparator`: deep clojure.lang/java-internal static interop. Park.
  - **clojure.core.match** — `definterface` (Tier-D-adjacent). **clojure.data.int-map**
    needs `clojure.core.reducers` (bundled-ns gap, D-273). **clojure.algo.monads**
    needs `clojure.tools.macro` (Compiler-dep, parked).

- **Opaque host-class VALUES (ADR-0109, 2026-06-07):** recognised JVM numeric
  classes cljw collapses away (java.math.BigInteger/Integer/Short/Byte/Float)
  now resolve as distinct class VALUES — `(= (type 5) Integer)`/`(instance?
  Integer 5)` clj-faithfully false, `(extend-type Integer …)` a load-only no-op
  (no crash). Advanced numeric-tower :98/:127 → :162. **java.lang.Object** is also
  wired as the universal supertype (`(isa? <any> Object)`→true, `(instance? Object
  x)`→non-nil) — **clojure.algo.generic (core ns) now LOADS** (its `(derive Object
  root-type)` was the blocker). **`java.lang.Number`** also wired (narrow members
  Long/Double/BigInt/Ratio/BigDecimal) — **clojure.algo.generic.arithmetic now
  LOADS**. Remainder (D-293 PARTIAL): `clojure.lang.IFn` (core.contracts) + other
  markers as class values (each its narrow membership), and a deeper functional
  gap — `(ga/+ 3 4)` mis-dispatches on the `[Number Number]` class-vector defmethod
  (loads but the generic-fn dispatch machinery, separate). **`clojure.lang.IFn`**
  also wired (value-resolution + isa? callable-members + matchInterface IFn fixed
  to full `ifn?`) — **clojure.core.contracts now LOADS** (with its core.unify dep).
  The CORE host-class-value markers (opaque-numerics / Object / Number / IFn) are
  now all landed.

- **clojure.math.numeric-tower** (probed 2026-06-07 via -cp): a DEEP java.math
  interop chain, parked. Advances :79 (D-301 empty-catch) → :98 (java.math.BigInteger
  class value, D-302) → :127 (Integer class value) → :162 (BigDecimal/ROUND_FLOOR
  static field), and beyond needs `.setScale`/`.bitLength` instance methods +
  `(BigDecimal. …)` ctors + extend-type on 8 host classes. Not a single-blocker
  rung — a full java.math interop unit blocked on D-293 (unified opaque/inert
  class-value resolver) + a BigDecimal surface. An exploratory opaque-class-VALUE
  probe (reverted) verified `(= (type 5) Integer)`/`(instance? Integer x)` are
  clj-faithful in isolation but COUPLED to extend-type (D-293); see debt D-293/D-302.

- **Re-probe (2026-06-07, after the ADR-0108/0109 arc)** — LOADS now:
  `clojure.algo.generic` (core + `.arithmetic` + `.comparison`) via the
  Object/Number/host-class-value markers, `clojure.core.contracts` (with its
  core.unify dep) via the IFn marker, plus the earlier set. **Frontier is now
  structural / host-surface / Tier-D** (clean single-fix wins harvested): D-075
  symbol-metadata layer (core.cache, algo.generic.math-functions — ADR-0037-deferred
  cross-cutting Symbol/Keyword/Var meta), clojure.lang internals (Util/RT statics,
  LazilyPersistentVector — host surfaces), reflection (tools.trace — Tier-D),
  clojure.lang.Compiler (tools.macro — Tier-D), threads (core.async — Phase B),
  java.io/StAX/Jackson (data.xml/json, instaparse — host surfaces). Each is a
  sizeable fresh unit; the next clean vein is the D-075 metadata layer or a
  clojure.lang.RT host surface.

- **Broad re-probe (2026-06-07)** after the D-287..D-299 arc found 7 libs now LOAD: clojure.data.csv, clojure.data.codec.base64 (over D-287 byte-arrays), clojure.core.unify, potpuri.core (deep-merge bit-identical to clj), bouncer.core, qbits.ex, and **clojure.data.zip** (D-299 ns-form leniency). Deferred/parked: symbol metadata = D-075 (interned symbols, structural); test.check = D-298 (proxy/Tier-D); tools.macro = clojure.lang.Compiler (Tier-D). Full table: private/notes/stage13-broad-reprobe.md.

- **Symbol-metadata layer LANDED (2026-06-07, D-304 / ADR-0110)** — `with-meta`/`meta` on a symbol now work (fresh non-interned gc.alloc'd symbol; ns+name-structural identity, meta-ignored; `.symbol` GC-membrane flip + trace). This was the blocker the frontier listed as "D-075 symbol-metadata layer" for **core.cache** + **algo.generic.math-functions** — re-probe both via hand-laid `-cp` when next fetched to confirm the load advances. Var/atom/ns/ref metadata is the remaining sibling (D-239).

## NEEDS-ROW gap summary (for the main loop)

These are candidate `debt.yaml` rows — the FIRST real blocker each library
hits. Do not edit `debt.yaml` from this doc; the main loop creates the rows.

1. ~~`NEEDS-ROW: java.util.regex.Pattern static method interop (Pattern/quote)`~~ — cuerdas rung 8. **LANDED 2026-06-07** (Pattern.zig `quote` static method; engine already honored `\Q…\E`; corpus `regex_pattern.txt`). Re-probe cuerdas for the next Pattern static (`compile`/`matches`/flags) when re-fetched.
2. ~~`NEEDS-ROW: java.util.Random seeded RNG`~~ — data.generators rung 5. **Rowed 2026-06-07 → D-289** (probed: fails at ns-load on the seeded ctor; stateful-native-object capability, sibling to D-288).
3. `NEEDS-ROW: javax.xml.stream StAX reader/writer` — data.xml rung 9.
4. `NEEDS-ROW: java.io FileNotFoundException catch + file slurp` — instaparse rung 10.
5. `NEEDS-ROW: java.io PrintWriter/PushbackReader/StringWriter + clojure.pprint` — data.json rung 11.
6. `NEEDS-ROW: threads/executors/go-macro` — core.async rung 14 (already Campaign Stage 1.7 / Phase B).

Cross-cutting blocker (not a single row): **no deps.edn / Maven resolver
yet** (Campaign Stage 1.2). Every transitive dependency must be fetched and
laid out by hand, which is what holds the `not-probed` rows back from being
load-verified.
