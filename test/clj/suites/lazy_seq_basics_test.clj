;; test/e2e/phase14_lazy_seq.sh
;;
;; Phase 14 §9.16 row 14.13.5 — lazy-seq Layer-2 cycle 1 (ADR-0054). Wire
;; the lazy_seq PRODUCER: `lazy-seq` macro + `__lazy-seq-create` primitive
;; (delay/future triad) + cons accepting an unforced lazy tail + `iterate`.
;; `take` is already lazy-aware-bounded, so it realizes only N elements of
;; an infinite lazy seq and returns a finite list (prints normally — the
;; print-API rt/env threading is deferred to cycle 2 when a lazy seq is a
;; top-level result).
;;
;; Proof: (take 5 (iterate inc 0)) → (0 1 2 3 4), without hanging.
;; Layer 2 (e2e CLI) per ADR-0021.

;; Migrated from test/e2e/phase14_lazy_seq.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.lazy-seq-basics-test
  (:require [clojure.test :refer [deftest is]]))

(deftest lazy-seq-basics-cases
  (is (= "(0 1 2 3 4)" (pr-str (take 5 (iterate inc 0)))) "iterate_take")
  (is (= "[0 1 2 3 4]" (pr-str (into [] (take 5 (iterate inc 0))))) "iterate_vec")
  (is (= "[1 2 4 8]" (pr-str (into [] (take 4 (iterate (fn* [x] (* x 2)) 1))))) "iterate_mul")
  (is (= "0" (pr-str (first (iterate inc 0)))) "iterate_first")
  (is (= "[1 2 3]" (pr-str (into [] (take 3 (lazy-seq (cons 1 (cons 2 (cons 3 nil)))))))) "lazy_seq_finite")
  (is (= "true" (pr-str (nil? (next (map identity [1]))))) "next_lazy_single_nil")
  (is (= "[9 1 3]" (pr-str (apply vector 9 (map identity [1 3])))) "apply_lazy_no_trailing_nil"))
