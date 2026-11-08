;; test/e2e/phase14_bignum_compare.sh
;;
;; Phase 14 §9.16 / cluster A26 (clj differential sweep, F-011) — D-167:
;; `<` / `>` / `<=` / `>=` (and `neg?` / `pos?`) were WRONG for BigInt /
;; Ratio / BigDecimal operands because lang/primitive/math.zig::pairwise
;; routed everything through toI64→f64, zeroing the big value. Fix: when no
;; operand is a float, route through compare.valueCompare (exact ordering
;; across the whole numeric tower); keep the f64 fast-path when a float is
;; present (IEEE NaN semantics + float contagion, where a total Order would
;; map NaN to .gt).

;; Migrated from test/e2e/phase14_bignum_compare.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.bignum-compare-test
  (:require [clojure.test :refer [deftest is]]))

(deftest bignum-compare-cases
  (is (= "true" (pr-str (neg? -5N))) "bigint_neg_small")
  (is (= "true" (pr-str (neg? Long/MIN_VALUE))) "bigint_neg_long_min")
  (is (= "true" (pr-str (pos? Long/MAX_VALUE))) "bigint_pos_long_max")
  (is (= "true" (pr-str (< -5N 0))) "bigint_lt_zero")
  (is (= "true" (pr-str (> Long/MAX_VALUE 0))) "bigint_gt_zero")
  (is (= "true" (pr-str (<= 5N 5N))) "bigint_le_equal")
  (is (= "true" (pr-str (< 1N 2N 3N))) "bigint_lt_chain")
  (is (= "true" (pr-str (< 1/3 1/2))) "ratio_lt")
  (is (= "false" (pr-str (< 1/2 1/3))) "ratio_lt_false")
  (is (= "true" (pr-str (>= 2/3 1/3))) "ratio_ge")
  (is (= "true" (pr-str (< 1.5M 2.5M))) "decimal_lt")
  (is (= "true" (pr-str (> 2.5M 1.5M))) "decimal_gt")
  (is (= "true" (pr-str (< 1 2 3))) "int_lt_chain")
  (is (= "false" (pr-str (< 3 2))) "int_lt_false")
  (is (= "true" (pr-str (< 1.5 2.5))) "float_lt")
  (is (= "true" (pr-str (>= 1.5 1.5))) "float_ge_equal")
  (is (= "false" (pr-str (> ##NaN 1))) "nan_gt_false")
  (is (= "false" (pr-str (< ##NaN 1))) "nan_lt_false")
  (is (= "false" (pr-str (>= ##NaN 1))) "nan_ge_false")
  (is (= "true" (pr-str (< 1/2 1))) "ratio_vs_int")
  (is (= "false" (pr-str (< 1/2 0.5))) "ratio_vs_float")
  (is (= "true" (pr-str (< 1.5M 2))) "decimal_vs_int")
  (is (= "true" (pr-str (== 1N 1))) "equiv_bigint_int")
  (is (= "false" (pr-str (== Long/MAX_VALUE 5))) "equiv_bigint_neq"))
