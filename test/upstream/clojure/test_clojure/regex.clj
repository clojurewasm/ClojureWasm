;; CLJW-ADD: Tests for regex operations
;; re-find, re-matches, re-seq, re-pattern, re-groups

(ns clojure.test-clojure.regex
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== re-find ==========

(deftest test-re-find
  (testing "simple match"
    (is (= "123" (re-find #"\d+" "abc123def"))))
  (testing "no match"
    (is (nil? (re-find #"\d+" "abcdef"))))
  (testing "with groups"
    (is (= ["123" "123"] (re-find #"(\d+)" "abc123def"))))
  (testing "at start"
    (is (= "abc" (re-find #"^abc" "abcdef")))))

;; ========== re-matches ==========

(deftest test-re-matches
  (testing "full match"
    (is (= "123" (re-matches #"\d+" "123"))))
  (testing "partial match fails"
    (is (nil? (re-matches #"\d+" "abc123"))))
  (testing "with groups"
    (is (= ["abc123" "abc" "123"] (re-matches #"(\w+?)(\d+)" "abc123")))))

;; ========== re-seq ==========

(deftest test-re-seq
  (testing "find all matches"
    (is (= ["1" "2" "3"] (re-seq #"\d" "a1b2c3"))))
  (testing "no matches"
    (is (= nil (seq (re-seq #"\d" "abc")))))
  (testing "with groups"
    (is (= [["a1" "a" "1"] ["b2" "b" "2"]]
           (re-seq #"([a-z])(\d)" "a1b2")))))

;; ========== re-pattern ==========

(deftest test-re-pattern
  (testing "create pattern from string"
    (let [p (re-pattern "\\d+")]
      (is (= "123" (re-find p "abc123"))))))

;; ========== regex as predicate ==========

(deftest test-regex-predicate
  (testing "re-find as filter predicate"
    (is (= ["abc" "axx"]
           (filter #(re-find #"^a" %) ["abc" "bcd" "axx"])))))

(run-tests)
