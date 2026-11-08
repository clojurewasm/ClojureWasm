;; test/e2e/phase14_map_complement_vector.sh
;;
;; D-134 residuals — `complement` multi-arg, `map` multi-coll (1/2/3-coll,
;; parallel, stop-at-shortest), and the `vector` fn. All Pattern A `.clj`.
;; (No diff_test: these are bootstrap `.clj` closures, which the Phase-4
;; compare harness can't cover cross-backend — D-152; e2e is the coverage.)

;; Migrated from test/e2e/phase14_map_complement_vector.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.map-complement-vector-test
  (:require [clojure.test :refer [deftest is]]))

(deftest map-complement-vector-cases
  (is (= "false" (pr-str ((complement <) 3 5))) "complement_multiarg")
  (is (= "true" (pr-str ((complement nil?) 5))) "complement_1arg")
  (is (= "(2 3 4)" (pr-str (map inc [1 2 3]))) "map_1coll")
  (is (= "(11 22 33)" (pr-str (map + [1 2 3] [10 20 30]))) "map_2coll")
  (is (= "(11 22)" (pr-str (map + [1 2 3] [10 20]))) "map_2coll_shortest")
  (is (= "(111 222)" (pr-str (map + [1 2] [10 20] [100 200]))) "map_3coll")
  (is (= "([:a 1] [:b 2])" (pr-str (map (fn* [a b] [a b]) [:a :b] [1 2]))) "map_zip")
  (is (= "[1 2 3]" (pr-str (vector 1 2 3))) "vector_args")
  (is (= "[]" (pr-str (vector))) "vector_empty")
  (is (= "([:a 1] [:b 2] [:c 3])" (pr-str (map vector [:a :b :c] [1 2 3]))) "map_vector_idiom")
  (is (= "[1 2 3]" (pr-str (apply vector [1 2 3]))) "apply_vector"))
