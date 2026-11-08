;; Double printing (D-149 whole-valued `.0`, D-166 scientific threshold).
;;
;; Whole-valued doubles print with a trailing `.0` (the JVM `Double.toString`
;; shape) so they read back as a double, not a long. Outside the decimal
;; window `1e-3 <= |x| < 1e7` (decimal exponent in [-3, 6]) the JVM switches
;; to `<d>.<dd>E<exp>`; the shared formatter runtime/print.zig::printFloat
;; re-lays Zig's shortest-scientific render to that shape, and eval/form.zig
;; delegates to it (F-011 commonisation). Every case is clj-grounded.
;;
;; Migrated from test/e2e/phase14_float_print.sh; each assertion keeps its
;; bash case name. The bash compared the PRINTED form, so these assert pr-str.
(ns suites.float-print-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- D-149: a whole-valued double keeps its `.0` ---
(deftest whole-valued-doubles-keep-the-point-zero
  (is (= "5.0" (pr-str 5.0)))                        ; whole_double
  (is (= "3.14" (pr-str 3.14)))                      ; frac_double
  (is (= "100.0" (pr-str 100.0)))                    ; pr_str_whole
  (is (= "5.0" (str 5.0)))                           ; str_whole
  (is (= "6.0" (pr-str (* 2.0 3))))                  ; arith_whole
  (is (= "0.25" (pr-str (/ 1.0 4))))                 ; div_frac
  (testing "the printed value still reads back as a float"
    (is (true? (float? (* 2.0 3))))))                ; still_float

;; --- signed zero: unary (- x) is IEEE negate, not (0 - x), so the sign bit
;; survives and the reciprocal is -Inf. (0 - 0.0) would give +0.0. ---
(deftest negative-zero-keeps-its-sign-bit
  (is (= "-0.0" (pr-str -0.0)))                      ; neg_zero
  (is (= "-0.0" (pr-str (- 0.0))))                   ; unary_neg_zero
  (is (= "-0.0" (pr-str (unchecked-negate 0.0))))    ; unchecked_neg_zero
  (is (= "-2.5" (pr-str (- 2.5))))                   ; unary_neg_nonzero
  (testing "and divides to -Inf"
    (is (= "##-Inf" (pr-str (/ 1.0 (- 0.0)))))))     ; unary_neg_zero_div

;; --- D-166: inside the decimal window, no exponent ---
(deftest decimal-window-prints-plainly
  (is (= "0.001" (pr-str 0.001)))                    ; dec_001
  (is (= "9999999.0" (pr-str 9999999.0)))            ; dec_max_under
  (is (= "100000.0" (pr-str 100000.0)))              ; dec_100k
  (is (= "123456.789" (pr-str 123456.789)))          ; dec_frac
  (is (= "0.3333333333333333" (pr-str (/ 1.0 3.0))))) ; dec_one_third

;; --- D-166: outside it, E-notation with a mantissa that always has a `.` ---
(deftest outside-the-window-uses-e-notation
  (is (= "1.0E7" (pr-str 1e7)))                      ; sci_1e7
  (is (= "1.2345678E7" (pr-str 12345678.0)))         ; sci_12345678
  (is (= "1.0E-4" (pr-str 0.0001)))                  ; sci_1e-4
  (is (= "6.022E23" (pr-str 6.022e23)))              ; sci_avogadro
  (is (= "1.0E20" (pr-str 1e20)))                    ; sci_1e20
  (is (= "-1.5E8" (pr-str -1.5e8)))                  ; sci_neg
  (is (= "1.0E-10" (pr-str 1e-10)))                  ; sci_small
  (is (= "1.0E7" (pr-str 1e7)))                      ; sci_pr_str
  (is (= "6.022E23" (str 6.022e23))))                ; sci_str

;; The smallest positive subnormal is the one shortest-digits case where Ryu
;; and the JVM disagree: cljw prints 5.0E-324, clj 4.9E-324 — the SAME f64 bit
;; pattern, only the decimal rendering differs. Recorded as an accepted
;; divergence carrying `pin: none` (a single edge, value bit-identical).
(deftest smallest-subnormal-renders-as-ryu-shortest
  (is (= "5.0E-324" (pr-str 5e-324))))               ; sci_min_subnormal
