;; Variadic fn* + apply / reduce / into and the predicate surface
;; (every? / some / not-every? / some?) — Phase 6.16.a-3.1 EXIT smoke.
;;
;; Migrated from test/e2e/composition_unlock_a3_1.sh; each assertion keeps its
;; bash case name. Set and map results assert VALUE equality rather than the
;; printed hash order (AD-001: unordered-collection print order is not
;; semantic).
(ns suites.composition-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- variadic fn* rest params ---
(deftest rest-params-collect-into-a-seq
  (is (= '(1 2 3) ((fn* [& xs] xs) 1 2 3)))              ; has_rest_basic
  (is (= [10 '(20 30)] ((fn* [a & xs] [a xs]) 10 20 30))) ; has_rest_mixed
  (testing "no trailing args gives an empty rest"
    (is (= 0 ((fn* [& xs] (count xs)))))))               ; has_rest_empty

(deftest apply-spreads-its-last-argument
  (is (= 10 (apply + [1 2 3 4])))                        ; apply_seq
  (is (= 10 (apply + 1 2 [3 4])))                        ; apply_lead_seq
  (testing "a nil tail spreads to nothing"
    (is (= 0 (apply + nil))))                            ; apply_nil_tail
  (is (= 4 (count (apply (fn* [& xs] xs) [1 2 3 4])))))  ; count_apply

(deftest reduce-with-and-without-an-init
  (is (= 10 (reduce + 0 [1 2 3 4])))                     ; reduce_init
  (is (= 10 (reduce + [1 2 3 4])))                       ; reduce_no_init
  (testing "an empty coll with no init uses the fn's zero-arity"
    (is (= 0 (reduce + []))))                            ; reduce_empty
  (testing "the accumulator drives the fn, so it can stop growing"
    (is (= 6 (reduce (fn* [acc x] (if (> acc 5) acc (+ acc x)))
                     0 [1 2 3 4 5 6]))))                 ; reduce_early
  (is (= #{1 2 3} (reduce conj (hash-set) [1 2 3]))))    ; reduce_conj_set

(deftest into-targets-any-collection
  (is (= [1 2 3] (into [] [1 2 3])))                          ; into_vec_from_vec
  (is (= #{1 2 3} (into (hash-set) [1 2 3])))                 ; into_set_from_vec
  (is (= {:a 1 :b 2} (into (hash-map) [[:a 1] [:b 2]]))))     ; into_map_kv_pairs

;; --- predicate surface ---
(deftest every?-and-not-every?
  (is (true? (every? pos? [1 2 3])))                     ; every_true
  (is (false? (every? pos? [1 -1 3])))                   ; every_false
  (testing "vacuously true on an empty coll"
    (is (true? (every? pos? []))))                       ; every_empty_true
  (is (true? (not-every? even? [2 4 5])))                ; not_every_t
  (is (false? (not-every? even? [2 4 6]))))              ; not_every_f

(deftest some-returns-the-first-truthy-result
  (is (true? (some pos? [-1 -2 3])))                     ; some_finds
  (is (nil? (some pos? [-1 -2 -3]))))                    ; some_none

;; some? is "not nil", so false and 0 are both some?
(deftest some?-is-not-nil
  (is (false? (some? nil)))                              ; some_q_nil
  (is (true? (some? 0)))                                 ; some_q_zero
  (is (true? (some? false))))                            ; some_q_false
