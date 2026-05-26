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
;; per D-NEW-2). The vector is built via `conj` rather than a vector
;; literal because the VM backend's compiler does not yet handle
;; `vector_literal_node` (D-060 — VM-side `op_vector_literal` lands
;; alongside Phase 7+ work).
(def juxt
  (fn* [f g] (fn* [x] (conj (conj [] (f x)) (g x)))))

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

(defprotocol IPersistentCollection (-count [c]) (-cons [c x]))
(defprotocol Seqable (-seq [c]))

