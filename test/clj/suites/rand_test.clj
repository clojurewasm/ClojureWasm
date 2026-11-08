;; test/e2e/phase14_rand.sh — D-134 rand / rand-int / rand-nth. Non-
;; deterministic (lazy-seeded process PRNG, runtime/random.zig), so the
;; assertions are RANGE / membership properties, not exact values.

;; Migrated from test/e2e/phase14_rand.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.rand-test
  (:require [clojure.test :refer [deftest is]]))

(deftest rand-cases
  (is (= "true" (pr-str (let [r (rand-int 10)] (and (>= r 0) (< r 10))))) "ri_range")
  (is (= "0" (pr-str (rand-int 0))) "ri_zero")
  (is (= "0" (pr-str (rand-int 1))) "ri_one")
  (is (= "true" (pr-str (let [r (rand)] (and (>= r 0.0) (< r 1.0))))) "r_unit")
  (is (= "true" (pr-str (let [r (rand 100)] (and (>= r 0.0) (< r 100.0))))) "r_scaled")
  (is (= "true" (pr-str (contains? #{:a :b :c} (rand-nth [:a :b :c])))) "rn_member")
  (is (= "true" (pr-str (let [r (rand-nth (range 50))] (and (>= r 0) (< r 50))))) "rn_range")
  (is (= "true" (pr-str (every? (fn* [_] (< (rand-int 3) 3)) (range 200)))) "ri_many"))
