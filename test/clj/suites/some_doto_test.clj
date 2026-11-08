;; test/e2e/phase14_some_doto.sh
;;
;; D-134 missing-core batch — conditional family: if-some / when-some / doto.
;; if-some/when-some are the nil-checking siblings of if-let/when-let (a
;; FALSE binding takes the then/body branch — the key distinction). doto
;; threads the first form-position with the value, evaluates to that value.
;; Side-effect observation is value-based only (println stdout is D-096;
;; atoms are Phase-15) — doto correctness is checked via return-value + that
;; threading evaluates without error (structurally identical to ->).

;; Migrated from test/e2e/phase14_some_doto.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.some-doto-test
  (:require [clojure.test :refer [deftest is]]))

(deftest some-doto-cases
  (is (= "10" (pr-str (if-some [x 5] (* x 2) :none))) "ifsome_then")
  (is (= ":none" (pr-str (if-some [x nil] (* x 2) :none))) "ifsome_nil")
  (is (= ":got-false" (pr-str (if-some [x false] :got-false :none))) "ifsome_false")
  (is (= ":missing" (pr-str (if-some [x (get {:a 1} :b)] x :missing))) "ifsome_miss")
  (is (= "nil" (pr-str (if-some [x nil] x))) "ifsome_noelse")
  (is (= ":e" (pr-str (if-let [x false] :t :e))) "iflet_false")
  (is (= ":t" (pr-str (if-some [x false] :t :e))) "ifsome_false2")
  (is (= "6" (pr-str (when-some [x 5] (+ x 1)))) "whensome_body")
  (is (= "nil" (pr-str (when-some [x nil] (+ x 1)))) "whensome_nil")
  (is (= "9" (pr-str (when-some [x 3] (inc x) (* x x)))) "whensome_multi")
  (is (= ":got" (pr-str (when-some [x false] :got))) "whensome_false")
  (is (= "5" (pr-str (doto 5 (+ 1) (* 2)))) "doto_num")
  (is (= "{:a 1}" (pr-str (doto {:a 1} (assoc :b 2) (assoc :c 3)))) "doto_map")
  (is (= "7" (pr-str (doto 7))) "doto_noforms"))
