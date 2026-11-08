;; test/e2e/phase14_comp_juxt_partition.sh
;;
;; D-134 residuals — clojure.core multi-arity: comp (0/1/2/N-ary, right-
;; to-left, any composed arity via apply), juxt (multi-fn + multi-arg),
;; partition 4-arg pad. All Pattern A `.clj` over existing primitives
;; (multi-arity fn* + apply + reduce + conj + concat).

;; Migrated from test/e2e/phase14_comp_juxt_partition.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.comp-juxt-partition-test
  (:require [clojure.test :refer [deftest is]]))

(deftest comp-juxt-partition-cases
  (is (= "3" (pr-str ((comp inc inc inc) 0))) "comp_3ary")
  (is (= "5" (pr-str ((comp) 5))) "comp_0ary")
  (is (= "6" (pr-str ((comp inc) 5))) "comp_1ary")
  (is (= "5" (pr-str ((comp inc dec) 5))) "comp_2ary")
  (is (= "\"6\"" (pr-str ((comp str inc) 5))) "comp_mixed")
  (is (= "7" (pr-str ((comp inc +) 1 2 3))) "comp_applyarity")
  (is (= "[6 4 \"5\"]" (pr-str ((juxt inc dec str) 5))) "juxt_3fn")
  (is (= "[13 7]" (pr-str ((juxt + -) 10 3))) "juxt_multiarg")
  (is (= "[6]" (pr-str ((juxt inc) 5))) "juxt_1fn")
  (is (= "((1 2) (3 4))" (pr-str (partition 2 [1 2 3 4]))) "partition_2arg")
  (is (= "((1 2) (3 4) (5 9))" (pr-str (partition 2 2 [9] [1 2 3 4 5]))) "partition_pad")
  (is (= "((1 2 3) (4 0))" (pr-str (partition 3 3 [0] [1 2 3 4]))) "partition_pad_short"))
