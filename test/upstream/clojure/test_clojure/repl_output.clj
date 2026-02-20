;; CLJW-ADD: Golden output tests for REPL-like expressions
;; Verifies pr-str produces correct Clojure-compatible output

(ns clojure.test-clojure.repl-output
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== pr-str golden output ==========

(deftest test-pr-str-primitives
  (testing "nil"
    (is (= "nil" (pr-str nil))))
  (testing "booleans"
    (is (= "true" (pr-str true)))
    (is (= "false" (pr-str false))))
  (testing "integers"
    (is (= "42" (pr-str 42)))
    (is (= "-1" (pr-str -1)))
    (is (= "0" (pr-str 0))))
  (testing "floats"
    (is (= "3.14" (pr-str 3.14)))
    (is (= "0.0" (pr-str 0.0))))
  (testing "strings"
    (is (= "\"hello\"" (pr-str "hello")))
    (is (= "\"\"" (pr-str "")))
    (is (= "\"hello\\nworld\"" (pr-str "hello\nworld")))
    (is (= "\"tab\\there\"" (pr-str "tab\there"))))
  (testing "characters"
    (is (= "\\a" (pr-str \a)))
    (is (= "\\space" (pr-str \space)))
    (is (= "\\newline" (pr-str \newline)))
    (is (= "\\tab" (pr-str \tab))))
  (testing "keywords"
    (is (= ":hello" (pr-str :hello)))
    (is (= ":foo/bar" (pr-str :foo/bar))))
  (testing "symbols"
    (is (= "hello" (pr-str 'hello)))
    (is (= "foo/bar" (pr-str 'foo/bar)))))

;; ========== pr-str collections ==========

(deftest test-pr-str-collections
  (testing "vectors"
    (is (= "[]" (pr-str [])))
    (is (= "[1 2 3]" (pr-str [1 2 3])))
    (is (= "[nil true false]" (pr-str [nil true false]))))
  (testing "lists"
    (is (= "()" (pr-str '())))
    (is (= "(1 2 3)" (pr-str '(1 2 3)))))
  (testing "sets"
    ;; set ordering may vary, just check it's a valid set repr
    (let [s (pr-str #{1})]
      (is (= "#{1}" s))))
  (testing "maps"
    (is (= "{}" (pr-str {})))
    ;; single-entry map has deterministic output
    (is (= "{:a 1}" (pr-str {:a 1})))))

;; ========== str golden output ==========

(deftest test-str-output
  (testing "str of nil is empty"
    (is (= "" (str nil))))
  (testing "str of primitives"
    (is (= "42" (str 42)))
    (is (= "3.14" (str 3.14)))
    (is (= "true" (str true)))
    (is (= "false" (str false)))
    (is (= "hello" (str "hello")))
    (is (= ":k" (str :k)))
    (is (= "sym" (str 'sym))))
  (testing "str concatenation"
    (is (= "123" (str 1 2 3)))
    (is (= "hello world" (str "hello" " " "world")))))

;; ========== print-method special types ==========

(deftest test-special-repr
  (testing "regex"
    (is (= "#\"\\d+\"" (pr-str #"\d+"))))
  (testing "ratio"
    (is (= "1/3" (pr-str 1/3)))
    (is (= "22/7" (pr-str 22/7))))
  (testing "uuid"
    (let [u (java.util.UUID/fromString "550e8400-e29b-41d4-a716-446655440000")]
      (is (= "#uuid \"550e8400-e29b-41d4-a716-446655440000\"" (pr-str u))))))

;; ========== println output ==========

(deftest test-println-output
  (testing "println appends newline"
    (is (= "42\n" (with-out-str (println 42)))))
  (testing "prn appends newline"
    (is (= "42\n" (with-out-str (prn 42)))))
  (testing "pr does not append newline"
    (is (= "42" (with-out-str (pr 42)))))
  (testing "print does not append newline"
    (is (= "42" (with-out-str (print 42))))))

(run-tests)
