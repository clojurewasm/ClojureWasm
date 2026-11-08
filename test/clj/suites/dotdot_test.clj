;; test/e2e/phase15_dotdot.sh — clojure.core `..` member-access threading macro.
;; `(.. x a b)` expands to `(. (. x a) b)`. cljw had no `..` macro and the
;; analyzer's `.`-prefixed dot-arms misparsed the `..` head as a `.` member
;; access, so `(.. s toString …)` raised "Unable to resolve symbol". The two
;; dot-arms now exclude the exact `..` head, letting it reach the macro.
;; Surfaced by honeysql's `(.. s toString (toUpperCase …))`. Layer 2.

;; Migrated from test/e2e/phase15_dotdot.sh. Original named assertions retain
;; their exact printed expectations.
(ns suites.dotdot-test
  (:require [clojure.test :refer [deftest is]]))

(deftest dotdot-cases
  (is (= "\"hi\"" (pr-str (.. "hi" toString))) "dotdot-one")
  (is (= "\"HI\"" (pr-str (.. "  hi  " trim toUpperCase))) "dotdot-chain")
  (is (= "\"BC\"" (pr-str (.. "abcde" toUpperCase (substring 1 3)))) "dotdot-args"))
