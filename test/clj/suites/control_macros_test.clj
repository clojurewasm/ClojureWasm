;; Trivial control macros — if-not / when / when-not / comment / cond.
;; Form transforms in src/lang/macro_transforms.zig (D-134).
;;
;; Converted from test/e2e/phase14_when_if_not.sh, which spent one cljw
;; process per assertion to evaluate expressions and compare printed output.
;; Nothing here touches the CLI surface (exit code, stderr, argv), so per
;; run_suites.clj's boundary the whole file belongs in the suite tier.
(ns suites.control-macros-test
  (:require [clojure.test :refer [deftest is testing]]))

;; --- if-not: the if branches, swapped ---
(deftest if-not-swaps-branches
  (testing "falsey test takes the first branch"
    (is (= :yes (if-not false :yes :no))))
  (testing "truthy test takes the else branch"
    (is (= :no (if-not true :yes :no))))
  (testing "no else branch yields nil"
    (is (nil? (if-not true :yes)))))

;; --- when-not: body runs on a falsey test; the last body form wins ---
(deftest when-not-runs-body-on-falsey
  (testing "multi-form body returns the last form"
    (is (= :b (when-not false :a :b))))
  (testing "truthy test skips the body"
    (is (nil? (when-not true :a))))
  (testing "the body is evaluated, not just returned"
    (is (= 42 (when-not (= 1 2) (* 6 7))))))

;; --- comment: reads its body (must be well-formed s-exprs) and discards it,
;; so the body may name symbols that do not resolve ---
(deftest comment-discards-its-body
  (testing "yields nil"
    (is (nil? (comment this is ignored))))
  (testing "the body is never evaluated, so undefined symbols are fine"
    (is (nil? (comment (totally-undefined 99)))))
  (testing "inside a do, the following forms still run"
    (is (= 42 (do (comment x) (+ 40 2))))))

;; --- expansion shape ---
;; `when` and `when-not` wrap their body in `(do …)` UNCONDITIONALLY — a
;; single-form and an empty body included — which is what clj emits. `when`
;; additionally uses a 2-arg `if` (no explicit nil else); a 2-arg `if` yields
;; nil on a false test, identical to `(if c then nil)`.
(deftest when-expands-like-clj
  (is (= '(if c (do a b)) (macroexpand-1 '(when c a b))))
  (is (= '(if c (do x)) (macroexpand-1 '(when c x))))
  (is (= '(if c (do)) (macroexpand-1 '(when c)))))

(deftest when-not-expands-like-clj
  (is (= '(if c nil (do x)) (macroexpand-1 '(when-not c x))))
  (is (= '(if c nil (do a b)) (macroexpand-1 '(when-not c a b))))
  (testing "an empty body is (do), not nil"
    (is (= '(if c nil (do)) (macroexpand-1 '(when-not c))))))

;; AD-040 pin: cljw's `cond` macroexpand-1 yields the FULL nested if, where clj
;; expands one clause and leaves a recursive `(clojure.core/cond …)`. The two
;; are functionally equal; this locks cljw's shape so a change is deliberate.
(deftest cond-expands-to-the-full-nested-if
  (is (= '(if a 1 (if :else 2 nil)) (macroexpand-1 '(cond a 1 :else 2)))))
