;; test/e2e/phase14_lazy_map.sh
;;
;; Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 2 (ADR-0054).
;; map/filter/keep/remove become lazy `.clj` (the -*-eager leaves are
;; deleted); the print path realizes a top-level lazy result so the REPL
;; renders `(2 3 4)`, not `#<lazy_seq>`. Laziness oracle uses `iterate`
;; (cycle 1) as the infinite source.
;;
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_lazy_map.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.lazy-map-test
  (:require [clojure.test :refer [deftest is]]))

(deftest lazy-map-cases
  (is (= "(2 3 4)" (pr-str (map inc [1 2 3]))) "map_print")
  (is (= "[2 3 4]" (pr-str (into [] (map inc [1 2 3])))) "map_into")
  (is (= "[1 3]" (pr-str (into [] (filter odd? [1 2 3 4])))) "filter_into")
  (is (= "[1 3]" (pr-str (into [] (keep (fn* [x] (if (odd? x) x nil)) [1 2 3 4])))) "keep_into")
  (is (= "[2 4]" (pr-str (into [] (remove odd? [1 2 3 4])))) "remove_into")
  (is (= "1" (pr-str (first (map inc (iterate inc 0))))) "map_lazy_first")
  (is (= "[1 2 3]" (pr-str (into [] (take 3 (map inc (iterate inc 0)))))) "map_lazy_take")
  (is (= "[]" (pr-str (into [] (map inc [])))) "map_empty")
  (is (= "\"(2 3 4)\"" (pr-str (str (map inc [1 2 3])))) "str_lazyseq_elements")
  (is (= "\"(0 :x 1 :x 2)\"" (pr-str (str (interpose :x (range 3))))) "str_interpose_lazy"))
