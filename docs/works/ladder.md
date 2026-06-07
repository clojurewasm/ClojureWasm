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
- **Rung 8 (cuerdas, partial):** loads after its `cuerdas.regexp` dependency
  is laid out, but `capitalize` (and other fns) hit
  `(java.util.regex.Pattern/quote ...)` — a static Java-class method call cljw
  does not resolve. This is the first *real* feature gap the ladder found, as
  opposed to a missing-resolver blocker.
- **Rungs 5, 9–14 (NEEDS-ROW):** static inspection shows each touches a Java
  surface cljw does not yet provide (seeded RNG, StAX XML, `java.io`
  reader/writer, Jackson, threads). These are the honest next gaps; the main
  loop converts each `NEEDS-ROW:` into a `debt.yaml` row classified against
  the Java-tier SSOT.
- **Rungs 13, 15 (not pure):** kept as boundary markers so the ladder makes
  explicit *where* the pure-Clojure frontier ends — they will not load without
  the underlying Java library, regardless of cljw progress.

## NEEDS-ROW gap summary (for the main loop)

These are candidate `debt.yaml` rows — the FIRST real blocker each library
hits. Do not edit `debt.yaml` from this doc; the main loop creates the rows.

1. `NEEDS-ROW: java.util.regex.Pattern static method interop (Pattern/quote)` — cuerdas rung 8, **confirmed by probe** (partial load).
2. ~~`NEEDS-ROW: java.util.Random seeded RNG`~~ — data.generators rung 5. **Rowed 2026-06-07 → D-289** (probed: fails at ns-load on the seeded ctor; stateful-native-object capability, sibling to D-288).
3. `NEEDS-ROW: javax.xml.stream StAX reader/writer` — data.xml rung 9.
4. `NEEDS-ROW: java.io FileNotFoundException catch + file slurp` — instaparse rung 10.
5. `NEEDS-ROW: java.io PrintWriter/PushbackReader/StringWriter + clojure.pprint` — data.json rung 11.
6. `NEEDS-ROW: threads/executors/go-macro` — core.async rung 14 (already Campaign Stage 1.7 / Phase B).

Cross-cutting blocker (not a single row): **no deps.edn / Maven resolver
yet** (Campaign Stage 1.2). Every transitive dependency must be fetched and
laid out by hand, which is what holds the `not-probed` rows back from being
load-verified.
