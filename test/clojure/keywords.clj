;; Ported from clojure/test_clojure/keywords.clj
;; Tests for keyword operations
;;
;; SKIP: test-find-keyword (find-keyword not implemented — no keyword intern table)
;; SKIP: arity-exceptions (thrown-with-msg?, regex, JVM exception types)
;;
;; Additional keyword operation tests added for coverage.

(ns test.keywords
  (:use clojure.test))

;; --- keyword constructor ---

(deftest t-keyword-from-string
  (is (= :foo (keyword "foo")))
  (is (= :bar (keyword "bar"))))

(deftest t-keyword-from-symbol
  (is (= :foo (keyword 'foo)))
  (is (= :a/b (keyword 'a/b))))

(deftest t-keyword-two-arg
  (is (= :a/b (keyword "a" "b")))
  (is (= :foo (keyword nil "foo"))))

(deftest t-keyword-identity
  (is (= :foo (keyword :foo)))
  (is (= :a/b (keyword :a/b))))

;; --- keyword? predicate ---

(deftest t-keyword-predicate
  (is (keyword? :foo))
  (is (keyword? :a/b))
  (is (not (keyword? 'foo)))
  (is (not (keyword? "foo")))
  (is (not (keyword? 42)))
  (is (not (keyword? nil))))

;; --- name / namespace ---

(deftest t-keyword-name
  (is (= "foo" (name :foo)))
  (is (= "bar" (name :a/bar))))

(deftest t-keyword-namespace
  (is (nil? (namespace :foo)))
  (is (= "a" (namespace :a/b)))
  (is (= "clojure.core" (namespace :clojure.core/map))))

;; --- equality ---

(deftest t-keyword-equality
  (is (= :foo :foo))
  (is (= :a/b :a/b))
  (is (not= :foo :bar))
  (is (not= :foo 'foo))
  (is (not= :a/b :c/b)))

;; --- keyword as function (IFn) ---

(deftest t-keyword-as-function
  (is (= 1 (:a {:a 1 :b 2})))
  (is (= 2 (:b {:a 1 :b 2})))
  (is (nil? (:c {:a 1 :b 2})))
  (is (= "default" (:c {:a 1} "default"))))

;; --- str on keyword ---

(deftest t-keyword-str
  (is (= ":foo" (str :foo)))
  (is (= ":a/b" (str :a/b))))

;; --- pr-str on keyword ---

(deftest t-keyword-pr-str
  (is (= ":foo" (pr-str :foo)))
  (is (= ":a/b" (pr-str :a/b))))

;; --- simple-keyword? / qualified-keyword? ---

(deftest t-simple-keyword?
  (is (true? (simple-keyword? :foo)))
  (is (true? (simple-keyword? :bar)))
  (is (false? (simple-keyword? :a/b)))
  (is (false? (simple-keyword? :clojure.core/map)))
  (is (false? (simple-keyword? 'foo)))
  (is (false? (simple-keyword? "foo")))
  (is (false? (simple-keyword? 42))))

(deftest t-qualified-keyword?
  (is (true? (qualified-keyword? :a/b)))
  (is (true? (qualified-keyword? :clojure.core/map)))
  (is (false? (qualified-keyword? :foo)))
  (is (false? (qualified-keyword? :bar)))
  (is (false? (qualified-keyword? 'a/b)))
  (is (false? (qualified-keyword? "a/b")))
  (is (false? (qualified-keyword? 42))))

(run-tests)
