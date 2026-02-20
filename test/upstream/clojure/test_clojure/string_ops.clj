;; CLJW-ADD: Tests for string operations
;; clojure.string namespace functions

(ns clojure.test-clojure.string-ops
  (:require [clojure.test :refer [deftest is testing run-tests]]
            [clojure.string :as str]))

;; ========== basic string fns ==========

(deftest test-string-basic
  (testing "upper-case / lower-case"
    (is (= "HELLO" (str/upper-case "hello")))
    (is (= "hello" (str/lower-case "HELLO"))))
  (testing "capitalize"
    (is (= "Hello" (str/capitalize "hello")))
    (is (= "Hello" (str/capitalize "HELLO")))
    (is (= "" (str/capitalize ""))))
  (testing "trim"
    (is (= "hello" (str/trim "  hello  ")))
    (is (= "hello" (str/triml "  hello")))
    (is (= "hello" (str/trimr "hello  "))))
  (testing "blank?"
    (is (str/blank? ""))
    (is (str/blank? "  "))
    (is (str/blank? nil))
    (is (not (str/blank? "x")))))

;; ========== split / join ==========

(deftest test-split-join
  (testing "split"
    (is (= ["a" "b" "c"] (str/split "a,b,c" #",")))
    (is (= ["a" "b,c"] (str/split "a,b,c" #"," 2))))
  (testing "join"
    (is (= "a,b,c" (str/join "," ["a" "b" "c"])))
    (is (= "abc" (str/join ["a" "b" "c"])))
    (is (= "" (str/join "," [])))))

;; ========== replace ==========

(deftest test-string-replace
  (testing "replace string"
    (is (= "hXllo" (str/replace "hello" "e" "X"))))
  (testing "replace regex"
    (is (= "hll" (str/replace "hello" #"[aeiou]" ""))))
  (testing "replace-first"
    (is (= "hXllo" (str/replace-first "hello" #"e" "X")))))

;; ========== predicates ==========

(deftest test-string-predicates
  (testing "starts-with?"
    (is (str/starts-with? "hello" "hel"))
    (is (not (str/starts-with? "hello" "world"))))
  (testing "ends-with?"
    (is (str/ends-with? "hello" "llo"))
    (is (not (str/ends-with? "hello" "world"))))
  (testing "includes?"
    (is (str/includes? "hello world" "lo wo"))
    (is (not (str/includes? "hello" "xyz")))))

;; ========== misc ==========

(deftest test-string-misc
  (testing "reverse"
    (is (= "olleh" (str/reverse "hello")))
    (is (= "" (str/reverse ""))))
  (testing "escape"
    (is (= "a&amp;b" (str/escape "a&b" {\& "&amp;"}))))
  (testing "re-quote-replacement"
    (is (string? (str/re-quote-replacement "test$1")))))

(run-tests)
