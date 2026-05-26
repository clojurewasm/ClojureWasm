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

(ns clojure.set (:refer-clojure))

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
              ;; PROVISIONAL: nth-based destructure pending let* vector destructure [refs: D-076, feature_deps.yaml#clojure.set/rename-keys]
              (let* [old (nth kv 0)
                     new-k (nth kv 1)]
                (if (contains? m old)
                  (assoc (dissoc acc old) new-k (get m old))
                  acc)))
            m
            kmap)))

;; `(map-invert m)` — swap keys and values. Matches JVM's transient
;; reduce-kv shape (D-074 cycle 3 discharged the PROVISIONAL marker).
(def map-invert
  (fn* [m]
    (persistent!
      (reduce (fn* [acc kv]
                (assoc! acc (nth kv 1) (nth kv 0)))
              (transient (hash-map))
              m))))

;; ----------------------------------------------------------------
;; Group C — relational ops (Phase 6.16.b-3). Sits on top of D-061
;; (#{} reader) + D-059 (map literal as Value) infra landed at
;; 6.16.b-2. select-keys / merge / set helpers come from core.clj.
;;
;; DIVERGENCE D-β: project / rename drop the JVM `with-meta` /
;; `meta` wrap because cw v1 has no value-metadata system yet
;; (Phase 7+ scope). join 3-arity `[xrel yrel km]` deferred to
;; D-070 closure; ships 2-arity natural join only.
;; ----------------------------------------------------------------

;; `(select pred xset)` — return the subset of `xset` whose
;; elements satisfy `pred`.
(def select
  (fn* [pred xset]
    (reduce (fn* [s k] (if (pred k) s (disj s k))) xset xset)))

;; `(project xrel ks)` — return a rel containing only the keys in
;; `ks` for each map in `xrel`.
(def project
  (fn* [xrel ks]
    ;; PROVISIONAL: drops with-meta wrap pending value metadata system [refs: D-075, feature_deps.yaml#clojure.set/project]
    (set (map (fn* [m] (select-keys m ks)) xrel))))

;; `(rename xrel kmap)` — return a rel with the keys in each map
;; renamed per kmap.
(def rename
  (fn* [xrel kmap]
    ;; PROVISIONAL: drops with-meta wrap pending value metadata system [refs: D-075, feature_deps.yaml#clojure.set/rename]
    (set (map (fn* [m] (rename-keys m kmap)) xrel))))

;; `(index xrel ks)` — return a map of (selected-keys → set-of-maps).
(def index
  (fn* [xrel ks]
    (reduce (fn* [m x]
              (let* [ik (select-keys x ks)]
                (assoc m ik (conj (get m ik #{}) x))))
            {}
            xrel)))

;; `(join xrel yrel)` — natural join on the common keys.
;; `(join xrel yrel km)` — arbitrary key mapping; `km` maps keys of
;; `xrel` to the corresponding keys of `yrel`. Multi-arity landed at
;; row 7.8 cycle 4 per ADR-0041 (D-070 discharge).
(def join
  (fn*
    ([xrel yrel]
     (if (and (seq xrel) (seq yrel))
       (let* [ks (intersection (set (keys (first xrel)))
                               (set (keys (first yrel))))
              smaller? (<= (count xrel) (count yrel))
              r (if smaller? xrel yrel)
              s (if smaller? yrel xrel)
              idx (index r ks)]
         (reduce (fn* [ret x]
                   (let* [found (get idx (select-keys x ks))]
                     (if found
                       (reduce (fn* [acc m] (conj acc (merge m x))) ret found)
                       ret)))
                 #{}
                 s))
       #{}))
    ([xrel yrel km]
     (let* [smaller? (<= (count xrel) (count yrel))
            r (if smaller? xrel yrel)
            s (if smaller? yrel xrel)
            k (if smaller? (map-invert km) km)
            idx (index r (vals k))]
       (reduce (fn* [ret x]
                 (let* [found (get idx (rename-keys (select-keys x (keys k)) k))]
                   (if found
                     (reduce (fn* [acc m] (conj acc (merge m x))) ret found)
                     ret)))
               #{}
               s)))))
