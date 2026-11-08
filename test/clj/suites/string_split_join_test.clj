;; Migrated from phase6_clojure_string_cycle4.sh. Every original case name
;; remains attached to its assertion; these cases share no mutable state.
(ns suites.string-split-join-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]))

(deftest capitalization
  (is (= "Hello" (str/capitalize "hello")) "capitalize_simple")
  (is (= "Hello world" (str/capitalize "HELLO WORLD")) "capitalize_lowers_rest")
  (is (= "" (str/capitalize "")) "capitalize_empty")
  (is (= "A" (str/capitalize "a")) "capitalize_single"))

(deftest splitting
  (is (= ["a" "b" "c"] (str/split "a,b,c" #",")) "split_comma")
  (is (= ["hello"] (str/split "hello" #",")) "split_no_match")
  (is (= ["a" "b" "c" "d"] (str/split "a-b-c-d" #"-")) "split_multi_match")
  (is (= [""] (str/split "" #",")) "split_empty_string")
  (is (= ["a" "b"] (str/split "a,b,," #",")) "split_drop_trailing_empties")
  (is (= ["" "a" "" "b"] (str/split ",a,,b" #",")) "split_keep_leading_interior")
  (is (= [] (str/split "," #",")) "split_all_empty_collapses")
  (is (= ["a" "b" "" ""] (str/split "a,b,," #"," -1)) "split_neg_limit_keeps")
  (is (= ["a" "b,c,d"] (str/split "a,b,c,d" #"," 2)) "split_pos_limit_2")
  (is (= ["a,b,c,d"] (str/split "a,b,c,d" #"," 1)) "split_pos_limit_1"))

(deftest splitting-lines
  (is (= ["line1" "line2" "line3"] (str/split-lines "line1\nline2\nline3")) "split_lines_lf")
  (is (= ["single"] (str/split-lines "single")) "split_lines_single"))

(deftest joining
  (is (= "abc" (str/join ["a" "b" "c"])) "join_no_sep")
  (is (= "a,b,c" (str/join "," ["a" "b" "c"])) "join_with_sep")
  (is (= "" (str/join "-" [])) "join_empty_coll")
  (is (= "solo" (str/join "-" ["solo"])) "join_single_element"))
