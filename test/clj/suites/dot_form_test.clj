;; test/e2e/phase15_dot_form.sh — the `.` interop special form (D-232).
;; `(. recv member)`, `(. recv member args…)`, and `(. recv (member args…))`
;; are the canonical interop primitive that `(.member recv …)` / `(Class/m …)`
;; sugar over. Lowers to the existing InteropCallNode: static when the receiver
;; is a class with the method, else an instance member. clj-grounded. Layer 2.

;; Migrated from test/e2e/phase15_dot_form.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.dot-form-test
  (:require [clojure.test :refer [deftest is]]))

(deftest dot-form-cases
  (is (= "\"ABC\"" (pr-str (. "abc" toUpperCase))) "inst-noarg")
  (is (= "\"bc\"" (pr-str (. "abcd" substring 1 3))) "inst-args")
  (is (= "\"bc\"" (pr-str (. "abcd" (substring 1 3)))) "inst-list")
  (is (= "3" (pr-str (. Math abs -3))) "static")
  (is (= "3" (pr-str (. Math (abs -3)))) "static-list")
  (is (= "\"HI\"" (pr-str (.toUpperCase "hi"))) "sugar-still"))
