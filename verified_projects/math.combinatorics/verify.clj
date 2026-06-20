;; clojure.math.combinatorics — pure lazy-seq combinatorial generators
;; (combinations / permutations / subsets / cartesian-product / selections /
;; partitions + the count-/nth-/index variants). 946-line .cljc contrib lib;
;; loads + runs VALUE-IDENTICAL to clj in cljw (the :clj reader-conditional
;; `Long/valueOf` branch + the lazy-seq machinery all resolve). Run by
;; `cljw -M:verify` (-> verify/-main). Assertions are value-based vs the clj
;; oracle (no accepted divergences — full parity).
(ns verify
  (:require [clojure.math.combinatorics :as combo]))

(defn -main [& _]
  (assert (= '((1 2) (1 3) (1 4) (2 3) (2 4) (3 4)) (combo/combinations [1 2 3 4] 2)))
  (assert (= '(() (1) (2) (3) (1 2) (1 3) (2 3) (1 2 3)) (combo/subsets [1 2 3])))
  (assert (= '((1 3) (1 4) (2 3) (2 4)) (combo/cartesian-product [1 2] [3 4])))
  (assert (= '((0 0 0) (0 0 1) (0 1 0) (0 1 1) (1 0 0) (1 0 1) (1 1 0) (1 1 1))
             (combo/selections [0 1] 3)))
  (assert (= '([1 2 3] [1 3 2] [2 1 3] [2 3 1] [3 1 2] [3 2 1]) (combo/permutations [1 2 3])))
  (assert (= '([1 1 2] [1 2 1] [2 1 1]) (combo/permutations [1 1 2])))   ; deduped
  (assert (= 3 (combo/count-permutations [1 1 2])))
  (assert (= 6 (combo/count-combinations [1 2 3 4] 2)))
  (assert (= 8 (combo/count-subsets [1 2 3])))
  (assert (= [0 3 2 1] (combo/nth-permutation [0 1 2 3] 5)))
  (assert (= [0 4] (combo/nth-combination (range 5) 2 3)))
  (assert (= 4 (combo/permutation-index [2 0 1])))
  (assert (= '([1 2] [2 1] [1 3] [3 1] [2 3] [3 2]) (combo/permuted-combinations [1 2 3] 2)))
  (assert (= '(([1 2 3]) ([1 2] [3]) ([1 3] [2]) ([1] [2 3]) ([1] [2] [3]))
             (combo/partitions [1 2 3])))
  (assert (= [0 1] (combo/nth-subset (range 4) 5)))
  (println "OK clojure.math.combinatorics: 15 assertions (combinations/permutations/"
           "subsets/cartesian-product/selections/partitions + count-/nth-/index variants)"))
