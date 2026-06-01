# clj-diff sweep coverage ledger (tracked)

Resume-time SSOT for "what the F-011 differential sweep has covered and what
to sweep next". Promoted to git from the gitignored running ledger
`private/notes/phaseA26-clj-differential-oracle.md` so a clean session's
`/continue` reaches it without depending on scratch. Run the sweep with
`scripts/clj_diff_sweep.sh` (see `.claude/rules/clj_diff_sweep.md`); land
confirmed exprs into a `*.txt` corpus here via `--corpus`.

## Swept & at parity (don't re-sweep wholesale)

- **Numeric tower** — `bigint`/`bigdec` constructors (int/BigInt/ratio/string/
  scientific/large-float), bigdec `+ - * / quot rem mod` contagion incl.
  float→f64, ratio terminating-decimal + ArithmeticException. (D-191/D-194
  discharged.)
- **Integer/Long bit + Math `*Exact`** — bitCount/clz/ctz/highestOneBit/reverse;
  addExact/multiplyExact/… (D-172). Remaining low-value: see Next.
- **String / regex** — clojure.string surface, `format` conversion+flag family,
  re-find/re-matches/re-seq + capturing groups + `$N`/fn replace; regex prints
  `#"src"` (pr) / raw (str).
- **Sequence / collection** — partition/interleave/reductions/mapcat/frequencies/
  group-by/dedupe/distinct/flatten/tree-seq/zipmap/merge-with/sort/sort-by/
  min-key/max-key/update(-in)/assoc-in/get-in (2+3-arity)/reduce-kv/juxt/comp/
  partial/subvec/replace/peek/pop/rseq/nthrest/take-last/drop-last (1+2-arity).
- **Transducer 1-arg (xform) arities** — map/filter/take/drop/keep/remove/
  map-indexed/keep-indexed/replace/take-while/drop-while/take-nth/partition-by/
  partition-all/dedupe/distinct/interpose/cat/mapcat (D-177 over-claim corrected).
- **Predicates** — number?/integer?/rational?/float?/double?/decimal?/ratio?/
  pos-int?/seqable?/coll?/associative?/indexed?/ident?/{simple,qualified}-
  {ident,keyword,symbol}?.
- **JSON (data.json)** — read/write number parity incl. BigInt both directions
  (D-182). `:bigdec` opt + ratio write are minor residuals.
- **destructuring** — vector `[a b & r :as all]` + missing→nil, map
  `:keys`/`:strs`/`:syms`/`{a :a}`/`:or`/`:as`, nested vector+map, fn-param +
  loop destructure, destructure on nil. All at parity (D-076 surface). Corpus
  `destructuring`.
- **clojure.edn/read-string** — vector/map/set/list/string/keyword/ratio/
  bigint/bigdec/float/bool/nil/neg/nested/quote literals + pr-str round-trip
  all at parity (only set print order + `(class)`→`Long` diverge, both
  acceptable). Corpus `edn_readstring`. (Tagged literals `#inst`/`#uuid` +
  custom `:readers` not yet probed.)
- **metadata (with-meta / vary-meta)** — meta read/attach on vector/map/list/
  set/seq, vary-meta assoc/update/multi-key/fn, nested re-wrap, `(with-meta x
  nil)`, meta-doesn't-affect-`=`, meta not printed. All at parity (no gaps).
  Corpus `metadata`. (`alter-meta!` on vars depends on var-metadata D-183.)
- **multimethod / hierarchy** — defmulti/defmethod dispatch, `:default`,
  custom dispatch fn, vector dispatch val, re-defmethod override; `derive` /
  `isa?` / `parents` / `ancestors` / `descendants` / `prefer-method`; gap
  found+fixed: `methods` / `get-method` / `remove-method` / `prefers` had no
  public wrapper over the rt/ primitives. no-match throws IllegalArgumentException
  (catchable; message format differs per F-011). Corpus `multimethod`.
- **`::` auto-resolved keyword** (D-195 discharged) — `::name`→current-ns,
  `::alias/name`→require-alias target ns; `(name ::foo)`/`(namespace ::foo)`/
  print/`=`/map-literal keys/multimethod `::` dispatch all at parity. Corpus
  `auto_keyword`. Residual: quoted `'::foo` interns `:foo` (formToValue has no
  env).
- **reduce / reduced / transduce** — reduce init/no-init/empty/nil, early
  `reduced`/`reduced?`/`unreduced`/`ensure-reduced`/`@reduced`, reduce-kv,
  reduce over map(entry)/set/string/range, transduce + xform compose. All at
  parity. Gap found+fixed: `key`/`val` were undefined (map entry = 2-vector →
  `(nth e 0/1)`). Corpus `reduce_reduced`.
- **Collections as keys / set elements** (D-092 discharged) — map / set / list
  AND cross-type vector≡list hash + compare by content (`(get {{:a 1} :x} {:a 1})`,
  `(get {[1 2] :v} '(1 2))`, set/`distinct`/`frequencies` dedup of collections,
  `clojure.set/index`/`join` map-key merge). `(hash coll)` is content-based +
  order-independent for maps/sets. Corpus `collection_keys`. Lazy/range keys
  stay identity (rt-free residual).

## Next-sweep candidates (gap-confirmed or unswept)

- **Low-value bit ops** (unswept, low call-frequency): Integer/Long
  `lowestOneBit`/`reverseBytes`/`rotateLeft`(2-arg)/`rotateRight`(2-arg)/`signum`.
- **`clojure.set` / `clojure.walk`** — swept 2026-06-02 (§A26): union/intersection/
  difference/subset?/superset?/select/project/rename/rename-keys/map-invert/index/
  join + prewalk/postwalk/*-replace/keywordize-keys/stringify-keys/walk all at
  parity (only set print order + the now-fixed collection-key bug diverged).
  Residual: `intersection`/`difference` 0-arity (cljw variadic returns nil; JVM has
  no 0-arity → ArityException) — low-value edge; `macroexpand-all` is a stub.
- **Unswept areas** worth a focused pass: `clojure.data/diff`, EDN tagged
  literals (`#inst`/`#uuid`/custom `:readers`), `alter-meta!` (needs
  var-metadata D-183).
- **`random-sample`** — undefined (1-arg transducer + 2-arg; non-deterministic).
- **Remaining Java interop** (structural-deferred, array/regex repr):
  `.split`/`.toCharArray`/`.getBytes` (needs F-004 Group-D `array` slot);
  `.replaceAll`/`.matches` (Pattern surface).

## Acceptable divergences (NOT bugs — do not "fix")

- Set / non-sorted-map **print order** differs from clj hash order.
- `(class 5)` → `Long` not `java.lang.Long` (ADR-0059 no-JVM rule); `(type …)` too.
- `(float 1/3)` is f64 (cljw has no f32).
- Subnormal `5.0E-324` vs JVM `4.9E-324` (same double).
- `Double/parseDouble` lower-case `inf`/`nan` + trailing `d`/`f` + hex-float —
  full Java FloatingDecimal grammar not reimplemented (rare edge).

## Structural-deferred (F-003 — big-bang, do NOT seize incrementally)

- **D-164** — `()` vs `nil` empty-seq unification (the single highest-leverage
  parity fix; collapses a whole class of diffs). `()` literal currently lowers
  to nil; empty lazy_seq prints `nil`; `rest`/`drop` collapse to nil.
- **D-165** — i48→i64 long print (`(2^47, 2^63]` long → BigInt `…N`); value-exact,
  print + `(class)` only. F-004 NaN-box payload consequence.
- D-086/D-088 (defrecord `__extmap` / protocol fqcn ns) · D-178/D-179 (seq-slot
  `.list`/`.cons`, `.string_seq`/`.array_seq` splits) · D-105 (java.time).
