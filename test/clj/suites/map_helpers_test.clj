;; test/e2e/phase14_map_helpers.sh
;;
;; Phase 14 §9.16 row 14.13 — D-134 cluster 2. Eager map/seq helpers:
;; reduce-kv / update-keys / update-vals / not-any? / butlast. Pure
;; Pattern A over reduce / keys / get / assoc / some / not / reverse /
;; rest / conj (no lazy-seq dependency). (dedupe/distinct/frequencies/
;; group-by need a working universal `=` — D-136 — and follow that fix.)
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_map_helpers.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.map-helpers-test
  (:require [clojure.test :refer [deftest is]]))

(deftest map-helpers-cases
  (is (= "3" (pr-str (reduce-kv (fn* [acc k v] (+ acc v)) 0 {:a 1 :b 2}))) "reduce_kv_sum")
  (is (= ":a" (pr-str (get (update-keys {1 :a} inc) 2))) "update_keys")
  (is (= "2" (pr-str (get (update-vals {:a 1} inc) :a))) "update_vals")
  (is (= "true" (pr-str (not-any? (fn* [x] (= x 9)) [1 2 3]))) "not_any_true")
  (is (= "false" (pr-str (not-any? (fn* [x] (= x 2)) [1 2 3]))) "not_any_false")
  (is (= "[1 2]" (pr-str (into [] (butlast [1 2 3])))) "butlast_vec"))

;; keys / vals demand a map, eagerly (AD-071).
;; clj answers nil for an EMPTY non-map (`(keys #{})`, `(keys "")`) and throws
;; on realization for a non-empty one, because its KeySeq wraps `seq(coll)` and
;; only casts each element when walked. cljw checks the argument instead, so
;; every non-map raises. These assertions pin cljw's side of that row: the empty
;; cases must keep RAISING rather than drifting to clj's nil, and a seq of
;; vector pairs must keep WORKING, where clj's per-element IMapEntry cast
;; rejects it.
(deftest keys-vals-demand-a-map
  (is (nil? (keys nil)))
  (is (nil? (vals nil)))
  (is (nil? (keys {})))
  (is (= [:a] (keys {:a 1})))
  (is (= [1] (vals {:a 1})))
  (is (thrown? Throwable (keys #{})))
  (is (thrown? Throwable (keys #{1})))
  (is (thrown? Throwable (keys "")))
  (is (thrown? Throwable (vals #{})))
  (is (thrown? Throwable (keys 0)))
  (is (= [:a] (keys (list [:a 1]))))
  (is (= [1] (vals (list [:a 1])))))

;; A key that is not `=` to itself (##NaN, or a list holding it) misses its
;; own lookup, so a keys-then-get walk lost its value and the print realize
;; pass grew a phantom `k nil` entry. Verified against JVM clj 1.12.
(deftest nan-key-entry-walk
  (is (= [1] (reduce-kv (fn* [acc k v] (conj acc v)) [] {##NaN 1})) "reduce_kv_nan_key")
  (is (= [2] (vec (vals (update-vals {##NaN 1} inc)))) "update_vals_nan_key")
  (is (= [1] (vec (vals (update-keys {##NaN 1} identity)))) "update_keys_nan_key")
  (is (= "{(##NaN) 1}" (pr-str {(list ##NaN) 1})) "print_list_nan_key_map")
  (is (= "#{(##NaN)}" (pr-str #{(list ##NaN)})) "print_list_nan_set")
  (is (= 2 (count (re-seq #"##NaN" (pr-str (hash-map (list ##NaN) 1 (list ##NaN) 2))))) "print_two_nan_keys"))
