;; SPDX-License-Identifier: EPL-2.0
;;
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for this software are covered by the
;;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php).
;;   By using this software in any fashion, you are agreeing to be bound by the
;;   terms of this license. You must not remove this notice, or any other, from
;;   this software.
;;
;;   clojure/set.clj — the IMPLEMENTATION is an independent reimplementation for
;;   ClojureWasm, but the docstrings are reproduced from Clojure's clojure.set
;;   (by Rich Hickey), so this file carries the upstream notice rather than
;;   claiming that no upstream text is reproduced (AD-059). Redistributed under
;;   EPL-2.0 per EPL-1.0 §7. ClojureWasm changes (c) the ClojureWasm authors.

;; clojure.set — Phase 6.16.b-1 (.clj migration).
;;
;; Loaded by `src/lang/bootstrap.zig::loadCore` per ADR-0032 multi-file
;; FILES table. The Group A + B vars (`union` / `intersection` /
;; `difference` / `subset?` / `superset?` / `rename-keys` /
;; `map-invert`) are pure-Clojure Pattern A defns per ADR-0033 D3 + v5
;; §8.2. Each composes `reduce` / `conj` / `disj` / `contains?` /
;; `every?` / `assoc` / `dissoc` / `get` / `count` from clojure.core — visible
;; unqualified here because the entered ns refers clojure.core
;; (commit 6.16.b-1 + ADR-0035 in Phase 6.16.b-4 codifies this as a
;; proper `(ns ...)` macro).
;;
;; union / intersection / difference are multi-arity `defn`s matching
;; upstream's arity sets. They were a single `[& sets]` rest-arg form until
;; 2026-08-04, sidestepping D-070 (multi-arity `fn*`) — long after D-070 was
;; discharged. That fossil cost two things: `:arglists` was nil for every var
;; here (a `def` + `fn*` carries none), and the 0-arity that upstream does NOT
;; define answered `nil` instead of raising, so `(intersection)` silently
;; produced a non-set.
;;
;; Group C (`select` / `project` / `index` / `rename` / `join`) lands
;; at 6.16.b-3 after D-061 (`#{}` reader literal) + D-059 (map-literal
;; analyzer) infra ships in 6.16.b-2.

(ns clojure.set (:refer-clojure))

(defn union
  "Return a set that is the union of the input sets"
  ([] (hash-set))
  ([s1] s1)
  ([s1 s2] (reduce conj s1 s2))
  ([s1 s2 & sets]
   (reduce (fn* [acc s] (reduce conj acc s)) s1 (cons s2 sets))))

(defn- intersect2
  [s1 s2]
  (reduce (fn* [acc x] (if (contains? s2 x) acc (disj acc x))) s1 s1))

(defn intersection
  "Return a set that is the intersection of the input sets"
  ([s1] s1)
  ([s1 s2] (intersect2 s1 s2))
  ([s1 s2 & sets] (reduce intersect2 (intersect2 s1 s2) sets)))

(defn difference
  "Return a set that is the first set without elements of the remaining sets"
  ([s1] s1)
  ([s1 s2] (reduce disj s1 s2))
  ([s1 s2 & sets] (reduce (fn* [a b] (reduce disj a b)) (reduce disj s1 s2) sets)))

(defn subset?
  "Is set1 a subset of set2?"
  [set1 set2]
  (if (<= (count set1) (count set2))
    (every? (fn* [x] (contains? set2 x)) set1)
    false))

(defn superset?
  "Is set1 a superset of set2?"
  [set1 set2]
  (subset? set2 set1))

;; `(rename-keys m kmap)` — rebuild m by replacing each old key in
;; kmap with its new-key partner. Skips entries whose old key is not
;; in m (matches JVM). The `(nth kv 0/1)` destructure substitutes
;; for vector binding inside `let*`.
(def rename-keys
  (fn* [m kmap]
    (reduce (fn* [acc kv]
              ;; nth over the map-entry vector is the Pattern-A finished form
              ;; (mirrors map-invert below); `let*` is the primitive special
              ;; form and never gains destructure — that is `let`'s job, which
              ;; this bootstrap-layer file deliberately avoids.
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
;; project / rename preserve source metadata via `with-meta` + `meta`
;; (value-metadata system landed). join ships the full 1/2/3-arity
;; surface, including the 3-arity `[xrel yrel km]` key-mapping form
;; (multi-arity `fn*` per ADR-0041 / D-070 discharge).
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
    (with-meta (set (map (fn* [m] (select-keys m ks)) xrel)) (meta xrel))))

;; `(rename xrel kmap)` — return a rel with the keys in each map
;; renamed per kmap.
(def rename
  (fn* [xrel kmap]
    (with-meta (set (map (fn* [m] (rename-keys m kmap)) xrel)) (meta xrel))))

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
