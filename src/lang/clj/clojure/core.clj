;; ClojureWasm Stage-1 prologue.
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` after
;; `primitive.registerAll` and `macro_transforms.registerInto`. The
;; head form is `(ns clojure.core (:refer-clojure))` per ADR-0035 D1
;; — the analyzer special form switches into clojure.core (creating
;; the ns at boot via `Env.init`, idempotent here) and honours
;; `:refer-clojure` (a no-op when we ARE clojure.core; kept for
;; surface-uniformity with the other bootstrap files).

(ns clojure.core (:refer-clojure))

(def not (fn* [x] (if x false true)))

;; ----------------------------------------------------------------
;; Phase 6.16.a-3.2 — eager higher-order surface (ADR-0033 D6 + v5 §5.2).
;;
;; Each surface fn delegates to its Zig leaf (`-foo-eager`) via the
;; `-name` Pattern B2 contract from ADR-0033 D4. Transducer 1-arg
;; arity (`(map f)` returning an xform) is **deferred** until cw v1
;; `fn*`/`defn` gains multi-arity support (tracked at D-NEW-2). For
;; this cycle these are eager-only forms — JVM `clojure.core/map` is
;; lazy, cw v1 `map` here builds the full list eagerly. The full
;; lazy + transducer semantics land at Phase 7+ once lazy-seq Layer
;; 2 wiring and multi-arity `fn*` both land.
;; ----------------------------------------------------------------

(def map (fn* [f coll] (-map-eager f coll)))
(def filter (fn* [pred coll] (-filter-eager pred coll)))
(def take (fn* [n coll] (-take-eager n coll)))
(def drop (fn* [n coll] (-drop-eager n coll)))
(def keep (fn* [f coll] (-keep-eager f coll)))
(def remove (fn* [pred coll] (-remove-eager pred coll)))

;; ----------------------------------------------------------------
;; Pure Clojure HOF (no Zig leaf) — pattern A per ADR-0033 D3.
;; ----------------------------------------------------------------

;; `(constantly x)` returns a fn that ignores its args and yields x.
(def constantly
  (fn* [x] (fn* [& _] x)))

;; `(complement pred)` returns a fn that negates pred's truthiness.
;; Single-arg only at this cycle (transducer arities + multi-arg
;; pred deferred per D-NEW-2).
(def complement
  (fn* [pred] (fn* [x] (not (pred x)))))

;; `(partial f & args)` partially applies f to the leading args.
;; The trailing arg list and the partial's captured args meet via
;; `(into (into [] args) more)` since cw v1 doesn't yet have
;; `concat`; the resulting vector goes through `apply`.
(def partial
  (fn* [f & args]
    (fn* [& more]
      (apply f (into (into [] args) more)))))

;; `(comp f g)` returns a fn that computes `(f (g x))`. Multi-fn
;; comp `(comp f g h)` deferred to D-NEW-2 multi-arity follow-up.
(def comp
  (fn* [f g] (fn* [x] (f (g x)))))

;; `(juxt f g)` returns a fn that yields a vector `[(f x) (g x)]`.
;; Two-fn form only at this cycle (multi-fn juxt + multi-arg deferred
;; per D-NEW-2).
(def juxt
  (fn* [f g] (fn* [x] [(f x) (g x)])))

;; ----------------------------------------------------------------
;; Phase 6.16.b-3 helpers — used by clojure.set Group C (project /
;; rename / index / join). Pattern A composition; no Zig leaves.
;; ----------------------------------------------------------------

;; `(select-keys m ks)` — return a map containing only the keys in
;; `ks` that are present in `m`. JVM uses `find` to distinguish
;; "absent" from "nil-valued"; cw v1 uses `contains?` (same
;; semantic when nil-values are absent — Phase 7+ value-meta layer
;; adds `find`).
(def select-keys
  (fn* [m ks]
    (reduce (fn* [acc k]
              (if (contains? m k)
                (assoc acc k (get m k))
                acc))
            {}
            ks)))

;; `(merge & maps)` — right-most key wins. nil args are skipped.
;; Variadic via `[& maps]`; 0-arity returns nil (matches JVM).
(def merge
  (fn* [& maps]
    (if (= 0 (count maps))
      nil
      (reduce (fn* [acc m]
                (if (nil? m)
                  acc
                  (reduce (fn* [a k] (assoc a k (get m k)))
                          acc
                          (keys m))))
              (first maps)
              (rest maps)))))

;; `(set coll)` — coerce a collection to a set. Duplicates collapse.
(def set
  (fn* [coll] (reduce conj #{} coll)))

;; ----------------------------------------------------------------
;; Phase 14 §9.16 row 14.13 — D-126 clojure.core daily-driver cluster.
;; Pattern A composition over reduce / get / assoc / first / next /
;; conj / into / apply. get-in/assoc-in/update-in walk a key path;
;; concat/mapcat are EAGER (DIVERGENCE: return a vector, not a lazy
;; seq — consistent with this file's eager map/filter surface; true
;; lazy lands with the lazy-seq Layer-2 wiring).
;; ----------------------------------------------------------------

;; `(get-in m ks)` — walk the key path `ks` through nested associatives.
;; Returns nil when any step is absent (get on nil is nil). The
;; 3-arity `[m ks not-found]` is deferred until multi-arity fn* lands.
(def get-in
  (fn* [m ks] (reduce get m ks)))

;; `(assoc-in m ks v)` — assoc `v` at the nested path `ks`, creating
;; intermediate maps as needed. `next` yields nil at the final key.
(def assoc-in
  (fn* [m ks v]
    (let [k (first ks) nks (next ks)]
      (if nks
        (assoc m k (assoc-in (get m k) nks v))
        (assoc m k v)))))

;; `(update-in m ks f & args)` — apply `f` (with trailing `args`) to
;; the value at the nested path `ks`. Recursive descent like assoc-in;
;; the leaf calls `(apply f old args)`.
(def update-in
  (fn* [m ks f & args]
    (let [k (first ks) nks (next ks)]
      (if nks
        (assoc m k (apply update-in (into [(get m k) nks f] args)))
        (assoc m k (apply f (into [(get m k)] args)))))))

;; `(concat & colls)` — eager left-to-right catenation into a vector.
;; DIVERGENCE from JVM (lazy seq); see cluster header.
(def concat
  (fn* [& colls]
    (reduce (fn* [acc c] (reduce conj acc c)) [] colls)))

;; `(mapcat f coll)` — map `f` over `coll`, eager-catenating the
;; per-element collections. Single-coll form (multi-coll deferred,
;; like `map`). DIVERGENCE from JVM (lazy seq); see cluster header.
(def mapcat
  (fn* [f coll]
    (reduce (fn* [acc x] (reduce conj acc (f x))) [] coll)))

;; ----------------------------------------------------------------
;; Phase 14 §9.16 row 14.13 — D-134 cluster 1. High-frequency eager
;; collection helpers (Pattern A over reduce/conj/assoc/get/into/apply).
;; ----------------------------------------------------------------

;; `(update m k f & args)` — apply `f` (with trailing `args`) to the
;; value at key `k`. The shallow sibling of `update-in`.
(def update
  (fn* [m k f & args]
    (assoc m k (apply f (into [(get m k)] args)))))

;; `(vec coll)` — eager coerce any collection to a vector.
(def vec
  (fn* [coll] (reduce conj [] coll)))

;; `(mapv f coll)` — eager `map` returning a vector. Single-coll form.
(def mapv
  (fn* [f coll] (reduce (fn* [acc x] (conj acc (f x))) [] coll)))

;; `(filterv pred coll)` — eager `filter` returning a vector.
(def filterv
  (fn* [pred coll]
    (reduce (fn* [acc x] (if (pred x) (conj acc x) acc)) [] coll)))

;; `(reverse coll)` — reverse order. conj onto an empty list prepends,
;; so reducing left-to-right yields the reversed sequence (a list).
;; `'()` (quoted) — a bare `()` is rejected as an empty-call expression.
(def reverse
  (fn* [coll] (reduce conj '() coll)))

;; `(last coll)` — the final element, or nil for an empty collection.
(def last
  (fn* [coll] (reduce (fn* [_ x] x) nil coll)))

;; ----------------------------------------------------------------
;; D-134 cluster 2 — eager map/seq helpers (Pattern A).
;; ----------------------------------------------------------------

;; `(reduce-kv f init m)` — reduce over a map's entries, calling
;; `(f acc k v)` for each key. Walks `(keys m)`.
(def reduce-kv
  (fn* [f init m]
    (reduce (fn* [acc k] (f acc k (get m k))) init (keys m))))

;; `(update-keys m f)` — new map with `(f k)` for each key, same vals.
(def update-keys
  (fn* [m f]
    (reduce (fn* [acc k] (assoc acc (f k) (get m k))) {} (keys m))))

;; `(update-vals m f)` — new map with `(f v)` for each val, same keys.
(def update-vals
  (fn* [m f]
    (reduce (fn* [acc k] (assoc acc k (f (get m k)))) {} (keys m))))

;; `(not-any? pred coll)` — true when `pred` is falsey for every item.
(def not-any?
  (fn* [pred coll] (not (some pred coll))))

;; D-134 cluster 3 — unblocked by D-136 (universal `=`).

;; `(dedupe coll)` — drop consecutive duplicates (eager vector).
(def dedupe
  (fn* [coll]
    (reduce (fn* [acc x] (if (= x (last acc)) acc (conj acc x))) [] coll)))

;; `(distinct coll)` — drop all duplicates, first occurrence wins.
;; Linear `=` scan (structural, so strings/collections dedupe); O(n^2).
(def distinct
  (fn* [coll]
    (reduce (fn* [acc x]
              (if (some (fn* [y] (= y x)) acc) acc (conj acc x)))
            []
            coll)))

;; `(frequencies coll)` — map of item -> occurrence count. Keys via map
;; assoc (bit-pattern keyEq → number/keyword keys; structural keys D-092).
(def frequencies
  (fn* [coll]
    (reduce (fn* [acc x] (assoc acc x (inc (get acc x 0)))) {} coll)))

;; `(group-by f coll)` — map of (f x) -> vector of items. Same key caveat.
(def group-by
  (fn* [f coll]
    (reduce (fn* [acc x] (let [k (f x)] (assoc acc k (conj (get acc k []) x))))
            {}
            coll)))

;; ----------------------------------------------------------------
;; D-134 cluster 4 — eager seq helpers (Pattern A; recursion for
;; zipmap/interleave).
;; ----------------------------------------------------------------

;; `(empty? coll)` — true when coll has no items (nil counts as empty).
(def empty?
  (fn* [coll] (= 0 (count coll))))

;; `(fnil f x)` — f with its first arg defaulted to x when nil.
;; 1-arg patched form (multi-arg fnil awaits multi-arity follow-up).
(def fnil
  (fn* [f x] (fn* [a] (f (if (nil? a) x a)))))

;; `(interpose sep coll)` — sep between consecutive items (eager).
;; Prepend sep before each, then drop the leading sep with `rest`.
(def interpose
  (fn* [sep coll]
    (rest (reduce (fn* [acc x] (conj (conj acc sep) x)) [] coll))))

;; `(zipmap ks vs)` — map pairing keys with values, stopping at the
;; shorter. Recursive parallel walk.
(def zipmap
  (fn* [ks vs]
    (if (or (empty? ks) (empty? vs))
      {}
      (assoc (zipmap (rest ks) (rest vs)) (first ks) (first vs)))))

;; `(interleave c1 c2)` — alternate items from two colls, stopping at
;; the shorter (eager vector). Two-coll form.
(def interleave
  (fn* [c1 c2]
    (if (or (empty? c1) (empty? c2))
      []
      (into (conj (conj [] (first c1)) (first c2))
            (interleave (rest c1) (rest c2))))))

;; ----------------------------------------------------------------
;; D-134 cluster 5 — reduce-shaped helpers (Pattern A).
;; sort / sort-by deferred (need a compare op + sort algorithm).
;; ----------------------------------------------------------------

;; `(max-key f & xs)` — the x with the greatest (f x); ties keep the
;; earlier-seen. `(min-key …)` is the mirror. reduce uses (first xs)
;; as the seed (≥1 arg required, matching JVM).
(def max-key
  (fn* [f & xs]
    (reduce (fn* [a b] (if (>= (f a) (f b)) a b)) xs)))

(def min-key
  (fn* [f & xs]
    (reduce (fn* [a b] (if (<= (f a) (f b)) a b)) xs)))

;; `(flatten coll)` — recursively splice nested sequentials into one
;; flat eager vector. Non-sequential leaves are kept.
(def flatten
  (fn* [coll]
    (reduce (fn* [acc x] (if (sequential? x) (into acc (flatten x)) (conj acc x)))
            []
            coll)))

;; `(reductions f init coll)` — like reduce but collects every
;; intermediate, starting with init (eager vector). 3-arg form;
;; the 2-arg `(reductions f coll)` awaits multi-arity.
(def reductions
  (fn* [f init coll]
    (reduce (fn* [acc x] (conj acc (f (last acc) x))) [init] coll)))

;; ----------------------------------------------------------------
;; D-134 cluster 6 — trivial accessors (no compare dependency).
;; sort / sort-by await D-137 (compare is numeric-only).
;; ----------------------------------------------------------------

;; `(second coll)` — the second item (nil if absent).
(def second (fn* [coll] (first (rest coll))))

;; `(ffirst coll)` — `(first (first coll))`.
(def ffirst (fn* [coll] (first (first coll))))

;; `(not-empty coll)` — coll if it has items, else nil.
(def not-empty (fn* [coll] (if (empty? coll) nil coll)))

;; `(take-last n coll)` — the last n items (eager).
(def take-last
  (fn* [n coll] (reverse (take n (reverse coll)))))

;; `(drop-last coll)` — all but the last item. 1-arg form (same body as
;; butlast, inlined to avoid a forward reference); the n-arity
;; `(drop-last n coll)` awaits multi-arity.
(def drop-last (fn* [coll] (reverse (rest (reverse coll)))))

;; ----------------------------------------------------------------
;; D-134 sort cluster — unblocked by D-137 (general compare).
;; STABLE merge sort (ADR-0053 D3: Clojure sort is stable). Eager
;; vector result (DIVERGENCE: JVM returns a seq). cmp returns -1/0/1.
;; ----------------------------------------------------------------

;; Stable merge of two cmp-sorted vectors; on a tie the left item wins
;; (`<=` keeps `a` first), preserving input order.
(def -merge-sorted
  (fn* [cmp a b]
    (if (empty? a)
      b
      (if (empty? b)
        a
        (if (<= (cmp (first a) (first b)) 0)
          (into (conj [] (first a)) (-merge-sorted cmp (rest a) b))
          (into (conj [] (first b)) (-merge-sorted cmp a (rest b))))))))

;; Merge sort over a vector with comparator `cmp`.
(def -msort
  (fn* [cmp v]
    (if (<= (count v) 1)
      v
      (let [mid (quot (count v) 2)]
        (-merge-sorted cmp
                       (-msort cmp (vec (take mid v)))
                       (-msort cmp (vec (drop mid v))))))))

;; `(sort coll)` — natural order via the general `compare` (stable).
(def sort
  (fn* [coll] (-msort compare (vec coll))))

;; `(sort-by f coll)` — order by `(compare (f a) (f b))` (stable).
(def sort-by
  (fn* [f coll]
    (-msort (fn* [a b] (compare (f a) (f b))) (vec coll))))

;; ----------------------------------------------------------------
;; D-134 eager-finite range + index fns. Eager vectors (DIVERGENCE:
;; JVM returns lazy seqs; the infinite 0-arg `(range)` awaits the
;; lazy-seq Layer-2 gap and is intentionally absent).
;; ----------------------------------------------------------------

;; Accumulate [start..end-1] into a vector (the eager range body).
(def -range-acc
  (fn* [i n acc] (if (>= i n) acc (-range-acc (inc i) n (conj acc i)))))

;; `(range n)` → [0..n-1]; `(range start end)` → [start..end-1]. Step
;; arity + infinite 0-arity await lazy-seq / multi-arity follow-ups.
(def range
  (fn* ([n] (-range-acc 0 n []))
       ([start end] (-range-acc start end []))))

;; ----------------------------------------------------------------
;; D-134 lazy cluster (ADR-0054 cycle 1). The lazy-seq PRODUCER is now
;; wired (`lazy-seq` macro + `__lazy-seq-create`), so genuinely infinite
;; seqs work: `take` realizes only what it needs (it walks first/rest,
;; which force `.lazy_seq` lazily).
;; ----------------------------------------------------------------

;; `(iterate f x)` — infinite lazy seq: x, (f x), (f (f x)), …
(def iterate
  (fn* [f x] (lazy-seq (cons x (iterate f (f x))))))

;; `(map-indexed f coll)` — eager map passing (index, item) to f.
(def map-indexed
  (fn* [f coll]
    (mapv (fn* [i] (f i (nth coll i))) (range (count coll)))))

;; `(keep-indexed f coll)` — like map-indexed but drops nil results.
(def keep-indexed
  (fn* [f coll]
    (reduce (fn* [acc i]
              (let [r (f i (nth coll i))] (if (nil? r) acc (conj acc r))))
            []
            (range (count coll)))))

;; `(butlast coll)` — all but the final element (eager list via reverse).
(def butlast
  (fn* [coll] (reverse (rest (reverse coll)))))

;; ----------------------------------------------------------------
;; Phase 7 §9.9 row 7.7 — hybrid polymorphic primitives' protocol surface.
;;
;; The `count` / `seq` / `conj` / `reduce` primitives keep their
;; Zig Tag-switch fast-path for native tags and route the slow-path
;; (= extend-type targets) through these protocol declarations. The
;; fqcn the slow-path matches in `MethodEntry.protocol_name` is the
;; bare symbol name (no ns prefix, per `allocFqcn` at
;; `lang/primitive/protocol.zig:41-51`), so `"IPersistentCollection"`
;; is the string the dispatch path uses.
;;
;; Methods land one per cycle: cycle 1 adds `-count`; cycles 2-4 add
;; `-seq` / `-cons` / `-reduce` as `seq` / `conj` / `reduce` are
;; wired into their hybrid shape.
;; ----------------------------------------------------------------

(defprotocol IPersistentCollection (-count [c]) (-cons [c x]) (-empty [c]))
(defprotocol Seqable (-seq [c]))
(defprotocol IReduce (-reduce [c f]))
(defprotocol ISeq (-first [s]) (-rest [s]) (-next [s]))
(defprotocol ILookup (-lookup [c k]))
(defprotocol Indexed (-nth [c i]))
(defprotocol Associative (-assoc [c k v]) (-contains-key? [c k]))
(defprotocol IPersistentMap (-without [m k]) (-keys [m]) (-vals [m]))
(defprotocol IPersistentSet (-disjoin [s k]))

