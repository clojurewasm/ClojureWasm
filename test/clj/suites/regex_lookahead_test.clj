;; test/e2e/phase14_regex_lookahead.sh
;;
;; Regex zero-width lookahead `(?=e)` / `(?!e)` (ADR-0115). Compiled to a `look`
;; inst whose sub-program runs anchored at the current position consuming nothing
;; (the Pike NFA's epsilon-closure runs it like an anchor). A positive lookahead's
;; inner captures thread through (full JVM parity, no divergence). Values
;; clj-oracle-confirmed. Unblocks honeysql (`honey.sql/dehyphen` uses `#"(\w)-(?=\w)"`).

;; Migrated from test/e2e/phase14_regex_lookahead.sh. Case names and printed expectations
;; are preserved; mutable values belong to their individual expressions.
(ns suites.regex-lookahead-test
  (:require [clojure.test :refer [deftest is]]))

(deftest regex-lookahead-cases
  (is (= "\"a b c\"" (pr-str (clojure.string/replace "a-b-c" #"(\w)-(?=\w)" "$1 "))) "dehyphen")
  (is (= "\"foo\"" (pr-str (re-find #"foo(?=bar)" "foobar"))) "pos_hit")
  (is (= "true" (pr-str (nil? (re-find #"foo(?=bar)" "foobaz")))) "pos_miss")
  (is (= "\"foo\"" (pr-str (re-find #"foo(?!bar)" "foobaz"))) "neg_hit")
  (is (= "true" (pr-str (nil? (re-find #"foo(?!bar)" "foobar")))) "neg_miss")
  (is (= "\"10\"" (pr-str (re-find #"\d+(?=px)" "10px"))) "no_consume")
  (is (= "(\"a\" \"b\")" (pr-str (re-seq #"\w+(?=,)" "a,b,c"))) "reseq")
  (is (= "\"x\"" (pr-str (re-find #"x(?=a|b)" "xb"))) "alt_look")
  (is (= "[\"abc\" \"abc\"]" (pr-str (re-find #"(?=(\w+))\w+" "abc"))) "cap_look")
  (is (= "[\"a-\" \"a\" \"b\"]" (pr-str (re-find #"(\w)-(?=(\w))" "a-b"))) "cap_mixed"))
