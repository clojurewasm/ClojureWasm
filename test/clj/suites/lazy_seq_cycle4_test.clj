;; test/e2e/phase14_lazy_seq_cycle4.sh
;;
;; Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 4 (ADR-0054 D6).
;; The LAST lazy-cluster cycle: repeat / repeatedly / cycle / take-while /
;; drop-while / partition become lazy `.clj`, mirroring the cycle-2/3
;; lazy-cons shape. With this, row 14.13.5 flips [ ] -> [x].
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_lazy_seq_cycle4.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.lazy-seq-cycle4-test
  (:require [clojure.test :refer [deftest is]]))

(deftest lazy-seq-cycle4-cases
  (is (= "[9 9 9 9]" (pr-str (into [] (take 4 (repeat 9))))) "repeat_inf")
  (is (= "(:x :x :x)" (pr-str (repeat 3 :x))) "repeat_n")
  (is (= "[]" (pr-str (into [] (repeat 0 :x)))) "repeat_zero")
  (is (= "[7 7 7]" (pr-str (into [] (take 3 (repeatedly (fn* [] 7)))))) "repeatedly_inf")
  (is (= "(1 1)" (pr-str (repeatedly 2 (fn* [] 1)))) "repeatedly_n")
  (is (= "[1 2 3 1 2 3 1]" (pr-str (into [] (take 7 (cycle [1 2 3]))))) "cycle_take")
  (is (= "5" (pr-str (first (cycle [5 6])))) "cycle_first")
  (is (= "[]" (pr-str (into [] (cycle [])))) "cycle_empty")
  (is (= "(1 2)" (pr-str (take-while (fn* [x] (< x 3)) [1 2 3 4 1]))) "takewhile")
  (is (= "[1 3 5]" (pr-str (into [] (take-while odd? [1 3 5 2 7])))) "takewhile_v")
  (is (= "[0 1 2]" (pr-str (into [] (take 3 (take-while (fn* [x] (< x 100)) (range)))))) "takewhile_inf")
  (is (= "(3 4 1)" (pr-str (drop-while (fn* [x] (< x 3)) [1 2 3 4 1]))) "dropwhile")
  (is (= "[4 5]" (pr-str (into [] (drop-while odd? [1 3 4 5])))) "dropwhile_v")
  (is (= "50" (pr-str (first (drop-while (fn* [x] (< x 50)) (range))))) "dropwhile_inf")
  (is (= "((1 2) (3 4))" (pr-str (partition 2 [1 2 3 4 5]))) "partition_2")
  (is (= "[(1 2) (3 4)]" (pr-str (into [] (partition 2 [1 2 3 4])))) "partition_v")
  (is (= "((1 2) (2 3) (3 4))" (pr-str (partition 2 1 [1 2 3 4]))) "partition_step")
  (is (= "[(0 1) (2 3)]" (pr-str (into [] (take 2 (partition 2 (range)))))) "partition_inf"))
