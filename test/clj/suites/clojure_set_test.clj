;; clojure.set — union / intersection / difference / subset? / superset? /
;; rename-keys / map-invert (Phase 6 groups A+B).
;;
;; Migrated from test/e2e/phase6_clojure_set_group_ab.sh; each assertion keeps
;; its bash case name. The script compared PRINTED sets and maps, which pinned
;; cljw's hash order as a side effect; AD-001 records that unordered-collection
;; print order is not semantic (it legitimately differs from clj), so these
;; assert VALUE equality instead — order-independent and a stronger claim.
(ns suites.clojure-set-test
  (:require [clojure.test :refer [deftest is testing]]
            [clojure.set :as set]))

(deftest union
  (is (= #{1 2 3} (set/union (hash-set 1 2) (hash-set 2 3))))    ; union_basic
  (is (= #{1 2} (set/union (hash-set 1) (hash-set 2))))          ; union_disjoint
  (testing "with an empty operand on either side"
    (is (= #{1 2} (set/union (hash-set) (hash-set 1 2))))        ; union_empty_l
    (is (= #{1 2} (set/union (hash-set 1 2) (hash-set))))))      ; union_empty_r

(deftest intersection
  (is (= #{2 3} (set/intersection (hash-set 1 2 3) (hash-set 2 3 4)))) ; inter_basic
  (is (= #{} (set/intersection (hash-set 1 2) (hash-set 3 4))))        ; inter_empty
  (is (= #{1 2} (set/intersection (hash-set 1 2) (hash-set 1 2)))))    ; inter_id

(deftest difference
  (is (= #{1} (set/difference (hash-set 1 2 3) (hash-set 2 3))))  ; diff_basic
  (is (= #{1 2} (set/difference (hash-set 1 2) (hash-set))))      ; diff_empty_r
  (is (= #{} (set/difference (hash-set 1 2) (hash-set 1 2)))))    ; diff_all

(deftest subset?-and-superset?
  (testing "subset?"
    (is (true? (set/subset? (hash-set 1 2) (hash-set 1 2 3))))    ; subset_true
    (is (true? (set/subset? (hash-set 1 2) (hash-set 1 2))))      ; subset_eq
    (is (true? (set/subset? (hash-set) (hash-set 1 2))))          ; subset_empty
    (is (false? (set/subset? (hash-set 1 4) (hash-set 1 2 3))))   ; subset_false
    (is (false? (set/subset? (hash-set 1 2 3) (hash-set 1 2))))) ; subset_bigger
  (testing "superset?"
    (is (true? (set/superset? (hash-set 1 2 3) (hash-set 1 2))))  ; super_true
    (is (true? (set/superset? (hash-set 1 2) (hash-set 1 2))))    ; super_eq
    (is (false? (set/superset? (hash-set 1 2) (hash-set 1 2 3)))))) ; super_false

(deftest rename-keys
  (is (= {:b 2 :A 1} (set/rename-keys (hash-map :a 1 :b 2) (hash-map :a :A)))) ; rename_basic
  (testing "a rename of an absent key changes nothing"
    (is (= {:a 1} (set/rename-keys (hash-map :a 1) (hash-map :missing :M))))) ; rename_absent
  (testing "an empty rename map is a no-op"
    (is (= {:a 1} (set/rename-keys (hash-map :a 1) (hash-map))))))  ; rename_noop

(deftest map-invert
  (is (= {1 :a 2 :b} (set/map-invert (hash-map :a 1 :b 2))))       ; invert_basic
  (is (= {} (set/map-invert (hash-map)))))                         ; invert_empty

(deftest operations-compose
  (is (true? (set/subset? (hash-set 1)
                          (set/union (hash-set 1) (hash-set 2)))))  ; subset_of_union
  (is (= #{2} (set/intersection
                (set/difference (hash-set 1 2 3) (hash-set 1))
                (hash-set 2)))))                                    ; inter_of_diff
