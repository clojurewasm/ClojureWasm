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
- **Coercion tower (`quot`/`rem`/`mod` + `int`/`long`/`num`/`double`/`float`/
  `numerator`/`denominator`/`rationalize`)** — all at parity over int/float/
  ratio/BigInt operands incl. truncation (`(int 3.7)`→3), `(num 1/2)`→ratio,
  `(rationalize 0.1)`→`1/10`, `(int \A)`→65. Corpus `coerce_tower` (27 exprs).
  Acceptable error-class divergences (both reject, see below): `(numerator 5)`,
  `(quot 10 0)`, `(mod 10 0)`.
- **Numeric coercion / parity** — `even?`/`odd?` over BigInt (incl. negative,
  zero, ≥2^64), plus **oversized integer-literal auto-promote**: a bare decimal
  literal too large for i64 now reads as BigInt (clj `…N`) instead of erroring,
  matching `(= 99…99 99…99N)`. Gap found+fixed: `even?`/`odd?` rejected `.big_int`
  (doc claimed a BigInt arm that was never wired) — now via `parity` helper
  (Long bottom-bit + BigInt least-significant-limb). Corpus `num_coerce`. (`*`
  overflow→`…N` vs clj ArithmeticException is F-005-intentional; large-Long→`…N`
  is D-165, both excluded from the corpus.) Residual: a **radix-prefixed**
  overflow (`0xFFFFFFFFFFFFFFFFFF`) still errors where clj promotes to BigInt —
  rare; `parseBase10` is base-10-only and the base-N setString path carries the
  D-047 Linux hazard, so deferred.
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
- **functions as values / HOF** — set/map/keyword/vector as fn (+ not-found),
  fnil/complement/every-pred/constantly/comp/partial/juxt, keyword-in-map/filter,
  keep-with-set, remove-with-set, group-by. Gap found+fixed: `some-fn` returned
  `nil` when no pred matched; clj returns the LAST pred's value (`(or …)`
  semantics: `((some-fn neg? even?) 3)`→false not nil). Corpus `fn_as_value`.
- **sequence fns (lazy tail)** — iterate/cycle/repeat/repeatedly/lazy-cat/
  split-at/split-with/butlast/take-while/nthrest/partition-all/keep/mapcat/
  reductions/range-step, infinite-bounded-by-take. Gap found+fixed:
  `interleave` was EAGER (returned empty for two infinite colls) — rewritten
  LAZY (JVM parity): `(take 4 (interleave (range) (repeat :x)))`→`(0 :x 1 :x)`;
  finite/uneven/1-arity preserved (0-arity → nil per D-164). Corpus `seq_tail`.
- **atom / swap! family** — atom/deref, swap! (fn / +args / update), reset!,
  compare-and-set! (hit + miss), swap-vals!/reset-vals! ([old new]), swap-over-
  collection, dotimes-swap, reset-then-swap — all at parity. Corpus `atom_swap`.
  (Watch family `add-watch`/`remove-watch` is Phase-15-deferred, D-157.)
- **clojure.string deeper edges** — split (limit + regex), replace
  (literal-string / regex / `$N` capture / fn), replace-first, includes?/
  starts-with?/ends-with?, blank?(+nil), triml/trimr, capitalize, join,
  split-lines, no-match replace. Gap found+fixed: `index-of`/`last-index-of`
  3-arity `from-index` (`(index-of s sub from)`→4, `(last-index-of s sub from)`
  = last start ≤ from) — both the primitive + the string.clj wrapper went
  variadic. Corpus `string_deep`.
- **exception / ex-info family** — `ex-info`/`ex-data`/`ex-message`, `ex-data`
  on non-ex→nil, `try`/`catch <Class>` (ExceptionInfo/Exception/Arithmetic/
  IndexOutOfBounds/AssertionError/Throwable)/`finally`, nested ex-data,
  `instance? ExceptionInfo` — the cljw-native error API at parity (16/18).
  Corpus `exception_api`. **`.getMessage`/`.getCause`/`.getData` LANDED**
  (D-198 partial): Java-interop read accessors on a caught/ex-info exception
  resolve via `.ex_info` native methods (Throwable.zig) — `(.getMessage e)` /
  `(:k (.getData e))` in catch bodies at parity on both backends, incl. a
  caught catalog error (`(/ 1 0)`). Corpus `host_exception` (6). **Remaining
  gap (D-198/D-048)**: `(Exception. msg)` host-class CONSTRUCTORS still
  `name_error` — use ex-info to mint exceptions (the native path).
- **vector / associative ops** — subvec (2+3-arity, empty), mapv/filterv,
  into (coll/xform/set/map), assoc (set + append-at-count), update (+args),
  get/nth (not-found), peek/pop, assoc-in/update-in/get-in (deep + not-found),
  replace, reduce-kv, into-sorted-map — all at parity (no gaps). Corpus
  `vec_assoc_ops`.
- **transients (mutation round-trip only)** — `transient`/`persistent!`
  round-trip (vector/map/set), `conj!`/`pop!`/`disj!`/`dissoc!`, `reduce conj!`,
  `reduce assoc!` at parity. Gap found+fixed: `assoc!` was 3-arity only — now
  `(assoc! t k1 v1 k2 v2 …)` multi-pair. `conj!` is single-element in BOTH
  (multi-arg → ArityException, F-011 class match). Corpus `transients`.
- **transients (read/query ops)** — `count`/`get`/`contains?`/`nth` on a live
  transient + `assoc!` on a transient *vector* (index-assign / append) now at
  parity across all 3 transient tags incl. hash-mode maps (>8 entries). clj
  treats a transient as a first-class read target; cljw now matches (was
  `type_error` / nil — D-199). Read accessors on
  `transient_{vector,array_map,hash_set}.zig` + the `.transient_*` arms wired
  into `count`/`get`/`contains?`/`nth`/`assoc!`. Corpus `transient_read` (21).
- **seq-return type class** — sort/sort-by/keys/vals/reverse/rest/next/seq/map/
  filter/distinct/take/drop/concat/remove/map-indexed/interpose/partition/
  flatten all return SEQS matching clj (NOT vectors — the feared sort-returns-
  vector class was a non-issue; only zip lefts/rights diverged, now fixed). Gap
  found+fixed: `array-map` constructor was unregistered (`name_error`) — now
  registered (cljw maps are array-backed ≤8, so array-map ≡ hash-map output for
  the small-map surface). Corpus `seq_return`.
- **clojure.zip** — vector-zip nav (down/up/right/left/next/node/root/edit/
  branch?/children/end?/append-child/insert-child) at parity. Gap found+fixed:
  `lefts`/`rights` returned the raw vector field; JVM returns a SEQ (`(1)` not
  `[1]`, empty→nil) — public fns now wrap `(seq …)` (internal nav still reads
  the vector fields). Corpus `zip`.
- **clojure.data/diff** (new ns) — recursive `[only-a only-b both]` over
  atom/map/set/sequential + nested, equal-shortcut, nil, growth. Pattern-A
  re-derivation over cljw predicates (no Java-interface protocols). Surfaced
  + fixed an independent bug: `(contains? vec i)` raised type_error — it now
  tests index validity (`true`/`false`, non-integer→false) per clj. Corpus
  `data_diff`.
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
- **Transient read/query ops** — CLOSED 2026-06-02 (D-199); see Swept areas.
- **Unswept areas** worth a focused pass: EDN tagged literals
  (`#inst`/`#uuid`/custom `:readers`), `alter-meta!` (needs var-metadata
  D-183), `clojure.walk/macroexpand-all` (stub), `clojure.string` deeper edges,
  transients (`transient`/`conj!`/`persistent!`), `clojure.core.async`-free
  concurrency primitives.
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
- **Error class name** on a rejected operation: cljw renders its own catalog
  Kind (`[type_error]` / `[arithmetic_error]`) where clj prints the JVM
  exception class (`ClassCastException` / `ArithmeticException`). Both correctly
  reject — e.g. `(numerator 5)`, `(quot 10 0)`, `(mod 10 0)`. ADR-0059 no-JVM.

## Structural-deferred (F-003 — big-bang, do NOT seize incrementally)

- **D-164** — `()` vs `nil` empty-seq unification (the single highest-leverage
  parity fix; collapses a whole class of diffs). `()` literal currently lowers
  to nil; empty lazy_seq prints `nil`; `rest`/`drop` collapse to nil.
- **D-165** — i48→i64 long print (`(2^47, 2^63]` long → BigInt `…N`); value-exact,
  print + `(class)` only. F-004 NaN-box payload consequence.
- D-086/D-088 (defrecord `__extmap` / protocol fqcn ns) · D-178/D-179 (seq-slot
  `.list`/`.cons`, `.string_seq`/`.array_seq` splits) · D-105 (java.time).
