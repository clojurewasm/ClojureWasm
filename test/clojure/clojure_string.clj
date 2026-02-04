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

(deftest t-capitalize
  (is (= "Foobar" (s/capitalize "foobar")))
  (is (= "Foobar" (s/capitalize "FOOBAR")))
  (is (= "Foobar" (s/capitalize "Foobar")))
  (is (= "" (s/capitalize ""))))

;; SKIP: t-escape (not implemented — needs higher-order fn)

(deftest t-replace-first
  (is (= "barbarfoo" (s/replace-first "foobarfoo" "foo" "bar")))
  (is (= "foobarfoo" (s/replace-first "foobarfoo" "baz" "bar")))
  (is (= "f$od" (s/replace-first "food" "o" "$"))))

(deftest t-split-lines
  (is (= ["one" "two" "three"] (s/split-lines "one\ntwo\nthree")))
  (is (= ["foo" "bar"] (s/split-lines "foo\r\nbar"))))

(deftest t-index-of
  (is (= 2 (s/index-of "hello" "ll")))
  (is (nil? (s/index-of "hello" "xyz")))
  (is (= 3 (s/index-of "hello" "l" 3))))

(deftest t-last-index-of
  (is (= 3 (s/last-index-of "hello" "l")))
  (is (nil? (s/last-index-of "hello" "xyz")))
  (is (= 2 (s/last-index-of "hello" "l" 2))))

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
