;; `=` universal value equality vs `==` numeric-tower equivalence
;; (Phase 14 §9.16 / D-136 / ADR-0052; the sorted-vs-hash arm is D-460).
;;
;; `=` is clojure.lang.Util.equiv: by-value across nil/bool/number/char/
;; keyword/symbol/string, structural for sequentials (vector and list compare
;; across types) and for maps/sets, numeric category-gated per F-005 so
;; (= 1 1.0) is false — and it never raises on a type mismatch. `==` widens
;; numeric categories instead.
;;
;; Migrated from test/e2e/phase14_equality.sh; each assertion keeps its bash
;; case name.
(ns suites.equality-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- scalars: these all used to raise type_error, which was the bug ---
(deftest scalars-compare-by-value
  (is (true? (= :a :a)))                      ; eq_kw_same
  (is (false? (= :a :b)))                     ; eq_kw_diff
  (is (true? (= nil nil)))                    ; eq_nil
  (is (true? (= "a" "a")))                    ; eq_str_same
  (is (false? (= "a" "b")))                   ; eq_str_diff
  (is (true? (= true true)))                  ; eq_bool
  (is (false? (= true false)))                ; eq_bool_diff
  (testing "a type mismatch is false, not an error"
    (is (false? (= 1 nil)))))                 ; eq_int_nil

;; --- collections compare structurally ---
(deftest collections-compare-structurally
  (is (true? (= [1 2] [1 2])))                ; eq_vec_same
  (is (false? (= [1 2] [1 3])))               ; eq_vec_diff
  (is (false? (= [1 2] [1 2 3])))             ; eq_vec_len
  (is (true? (= [1 [2 3]] [1 [2 3]])))        ; eq_nested
  (is (true? (= {:a 1} {:a 1})))              ; eq_map_same
  (is (false? (= {:a 1} {:a 2})))             ; eq_map_diff
  (is (true? (= #{1 2} #{2 1}))))             ; eq_set_same

;; --- sequentials compare ACROSS types; a set is not sequential ---
(deftest sequentials-compare-across-types
  (is (true? (= [1 2] '(1 2))))               ; eq_seq_cross
  (is (false? (= #{1} [1]))))                 ; eq_set_not_vec

;; --- F-005: `=` is category-gated, `==` widens ---
(deftest numeric-category-gate
  (is (true? (= 1 1)))                        ; eq_int_same
  (testing "= does NOT cross the int/float category"
    (is (false? (= 1 1.0))))                  ; eq_int_float
  (testing "== does"
    (is (true? (== 1 1.0)))                   ; equiv_int_float
    (is (true? (== 2 2)))))                   ; equiv_int_int

;; --- D-460: sets and maps are `=` by ELEMENTS across implementations, so a
;; sorted collection equals a hash one with the same contents. The dispatch
;; previously had no sorted_set/sorted_map arm. ---
(deftest sorted-and-hash-compare-by-elements
  (is (true? (= (sorted-set 1 2 3) #{3 2 1})))          ; eq_sortedset_hashset
  (is (true? (= #{1 2} (sorted-set 2 1))))              ; eq_hashset_sortedset
  (is (true? (= (sorted-set 1 2) (sorted-set 2 1))))    ; eq_sortedset_self
  (is (true? (= (sorted-map :a 1 :b 2) {:b 2 :a 1})))   ; eq_sortedmap_hashmap
  (testing "differing contents are still unequal"
    (is (false? (= (sorted-set 1 2) #{1 3})))           ; eq_sortedset_neq
    (is (false? (= (sorted-map :a 1) {:a 2})))))        ; eq_sortedmap_valneq
