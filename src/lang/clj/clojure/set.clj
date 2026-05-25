;; clojure.set — Phase 6.16.b-1 (.clj migration).
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` per ADR-0032 multi-file
;; FILES table. The Group A + B vars (`union` / `intersection` /
;; `difference` / `subset?` / `superset?` / `rename-keys` /
;; `map-invert`) are pure-Clojure Pattern A defns per ADR-0033 D3 + v5
;; §8.2. Each composes `reduce` / `conj` / `disj` / `contains?` /
;; `every?` / `assoc` / `dissoc` / `get` / `count` from rt/ — visible
;; unqualified here because `evalInNs` refers rt/ into the entered ns
;; (commit 6.16.b-1 + ADR-0035 in Phase 6.16.b-4 codifies this as a
;; proper `(ns ...)` macro).
;;
;; **Variadic via [& sets] + internal arity discrimination**: union /
;; intersection / difference accept 0/1/2/3+ args using a single
;; rest-arg `fn*` form (no multi-arity dispatch needed). This sidesteps
;; D-070 (multi-arity `fn*`) for these three vars — the survey's D-070
;; back-fill plan is therefore void for this group.
;;
;; Group C (`select` / `project` / `index` / `rename` / `join`) lands
;; at 6.16.b-3 after D-061 (`#{}` reader literal) + D-059 (map-literal
;; analyzer) infra ships in 6.16.b-2.

(in-ns 'clojure.set)

(def union
  (fn* [& sets]
    (if (= 0 (count sets))
      (hash-set)
      (reduce (fn* [acc s] (reduce conj acc s))
              (first sets)
              (rest sets)))))

(def intersection
  (fn* [& sets]
    (if (= 0 (count sets))
      nil
      (if (= 1 (count sets))
        (first sets)
        (reduce (fn* [s1 s2]
                  (reduce (fn* [acc x]
                            (if (contains? s2 x) acc (disj acc x)))
                          s1
                          s1))
                (first sets)
                (rest sets))))))

(def difference
  (fn* [& sets]
    (if (= 0 (count sets))
      nil
      (if (= 1 (count sets))
        (first sets)
        (reduce (fn* [s1 s2] (reduce disj s1 s2))
                (first sets)
                (rest sets))))))

(def subset?
  (fn* [s1 s2]
    (if (<= (count s1) (count s2))
      (every? (fn* [x] (contains? s2 x)) s1)
      false)))

(def superset?
  (fn* [s1 s2] (subset? s2 s1)))

;; `(rename-keys m kmap)` — rebuild m by replacing each old key in
;; kmap with its new-key partner. Skips entries whose old key is not
;; in m (matches JVM). The `(nth kv 0/1)` destructure substitutes
;; for vector binding inside `let*`.
(def rename-keys
  (fn* [m kmap]
    (reduce (fn* [acc kv]
              (let* [old (nth kv 0)
                     new-k (nth kv 1)]
                (if (contains? m old)
                  (assoc (dissoc acc old) new-k (get m old))
                  acc)))
            m
            kmap)))

;; `(map-invert m)` — swap keys and values. JVM uses a transient
;; reduce-kv for O(n) cost; cw v1 uses persistent reduce since
;; transients land at Phase 8 (DIVERGENCE D-α per per-task survey).
(def map-invert
  (fn* [m]
    (reduce (fn* [acc kv]
              (assoc acc (nth kv 1) (nth kv 0)))
            (hash-map)
            m)))
