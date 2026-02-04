;; IO function tests — print, pr, slurp, spit, print-str, prn-str, println-str
;; SKIP: printer.clj upstream tests (require binding, *print-length*, pprint — F85)
;; SKIP: read-line tests (requires stdin interaction, not automatable in test runner)

(ns clojure.test-clojure.io
  (:use clojure.test))

;; === print-str ===

(deftest test-print-str
  (testing "no args returns empty string"
    (is (= "" (print-str))))
  (testing "string is unquoted"
    (is (= "hello" (print-str "hello"))))
  (testing "multi-arg space separated"
    (is (= "1 hello" (print-str 1 "hello"))))
  (testing "nil prints empty"
    (is (= "" (print-str nil))))
  (testing "keyword prints with colon"
    (is (= ":foo" (print-str :foo)))))

;; === pr-str ===

(deftest test-pr-str
  (testing "no args returns empty string"
    (is (= "" (pr-str))))
  (testing "string is quoted"
    (is (= "\"hello\"" (pr-str "hello"))))
  (testing "nil prints nil"
    (is (= "nil" (pr-str nil))))
  (testing "multi-arg readable"
    (is (= "1 \"hello\" nil" (pr-str 1 "hello" nil))))
  (testing "keyword"
    (is (= ":foo" (pr-str :foo))))
  (testing "vector"
    (is (= "[1 2 3]" (pr-str [1 2 3]))))
  (testing "map"
    (is (= "{:a 1}" (pr-str {:a 1})))))

;; === prn-str ===

(deftest test-prn-str
  (testing "no args returns newline"
    (is (= "\n" (prn-str))))
  (testing "string is quoted with newline"
    (is (= "\"hello\"\n" (prn-str "hello"))))
  (testing "multi-arg"
    (is (= "1 nil\n" (prn-str 1 nil)))))

;; === println-str ===

(deftest test-println-str
  (testing "no args returns newline"
    (is (= "\n" (println-str))))
  (testing "string is unquoted with newline"
    (is (= "hello\n" (println-str "hello"))))
  (testing "multi-arg"
    (is (= "1 hello\n" (println-str 1 "hello")))))

;; === slurp + spit ===

(deftest test-slurp-spit-roundtrip
  (let [path "/tmp/cljw_test_roundtrip.txt"
        content "hello world"]
    (spit path content)
    (is (= content (slurp path)))))

(deftest test-spit-overwrite
  (let [path "/tmp/cljw_test_overwrite.txt"]
    (spit path "first")
    (spit path "second")
    (is (= "second" (slurp path)))))

(deftest test-spit-append
  (let [path "/tmp/cljw_test_append.txt"]
    (spit path "hello")
    (spit path " world" :append true)
    (is (= "hello world" (slurp path)))))

(deftest test-spit-non-string
  (let [path "/tmp/cljw_test_nonstr.txt"]
    (spit path 42)
    (is (= "42" (slurp path)))))

(deftest test-spit-multiline
  (let [path "/tmp/cljw_test_multi.txt"
        content "line1\nline2\nline3"]
    (spit path content)
    (is (= content (slurp path)))))

;; === str function (print-related) ===

(deftest test-str-print-basics
  (testing "str of nil"
    (is (= "" (str nil))))
  (testing "str concat"
    (is (= "hello world" (str "hello" " " "world"))))
  (testing "str of number"
    (is (= "42" (str 42))))
  (testing "str of keyword"
    (is (= ":foo" (str :foo))))
  (testing "str of boolean"
    (is (= "true" (str true)))))

;; Run tests
(run-tests)
