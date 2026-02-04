;; Ported from clojure/test_clojure/string.clj
;; Tests for clojure.string namespace

(ns test.clojure-string
  (:use clojure.test)
  (:require [clojure.string :as s]))

(deftest t-split
  ;; SKIP: regex #"..." tests (regex not implemented)
  (is (= ["a" "b"] (s/split "a-b" "-")))
  (is (= ["a" "b" "c"] (s/split "a-b-c" "-"))))
  ;; SKIP: (s/split s re limit) not tested (regex)

(deftest t-reverse
  (is (= "tab" (s/reverse "bat"))))

(deftest t-replace
  ;; String replacement
  (is (= "barbarbar" (s/replace "foobarfoo" "foo" "bar")))
  (is (= "foobarfoo" (s/replace "foobarfoo" "baz" "bar")))
  (is (= "f$$d" (s/replace "food" "o" "$"))))
  ;; SKIP: regex replacement tests
  ;; SKIP: char replacement tests (\o \a — char literal)

(deftest t-join
  ;; No separator
  (is (= "" (s/join nil)))
  (is (= "" (s/join [])))
  (is (= "1" (s/join [1])))
  (is (= "12" (s/join [1 2])))
  ;; With separator
  (is (= "1,2,3" (s/join "," [1 2 3])))
  (is (= "" (s/join "," [])))
  (is (= "1" (s/join "," [1])))
  (is (= "1 and-a 2 and-a 3" (s/join " and-a " [1 2 3]))))

(deftest t-trim-newline
  (is (= "foo" (s/trim-newline "foo\n")))
  (is (= "foo" (s/trim-newline "foo\r\n")))
  (is (= "foo" (s/trim-newline "foo")))
  (is (= "" (s/trim-newline ""))))

;; SKIP: t-capitalize (not implemented)
;; SKIP: t-escape (not implemented)
;; SKIP: t-replace-first (not implemented)
;; SKIP: t-split-lines (not implemented)
;; SKIP: t-index-of (not implemented)
;; SKIP: t-last-index-of (not implemented)

(deftest t-triml
  (is (= "foo " (s/triml " foo ")))
  (is (= "" (s/triml "   "))))

(deftest t-trimr
  (is (= " foo" (s/trimr " foo ")))
  (is (= "" (s/trimr "   "))))

(deftest t-trim
  (is (= "foo" (s/trim "  foo  \r\n"))))

(deftest t-upper-case
  (is (= "FOOBAR" (s/upper-case "Foobar"))))

(deftest t-lower-case
  (is (= "foobar" (s/lower-case "FooBar"))))

(deftest t-blank
  (is (s/blank? nil))
  (is (s/blank? ""))
  (is (s/blank? " "))
  (is (s/blank? " \t \n  \r "))
  (is (not (s/blank? "  foo  "))))

(deftest t-includes
  (is (s/includes? "Clojure Applied Book" "Applied"))
  (is (not (s/includes? "Clojure Applied Book" "Living"))))

(deftest t-starts-with
  (is (s/starts-with? "clojure west" "clojure"))
  (is (not (s/starts-with? "conj" "clojure"))))

(deftest t-ends-with
  (is (s/ends-with? "Clojure West" "West"))
  (is (not (s/ends-with? "Conj" "West"))))

(run-tests)
