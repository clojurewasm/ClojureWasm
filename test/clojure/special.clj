;; Ported from clojure/test_clojure/special.clj
;; Tests for special forms: let destructuring
;;
;; PARTIAL PORT: 5/14 tests ported (T17.5: +syms, +keyword-args destructuring)
;; SKIP: 9 tests - JVM-specific (thrown-with-cause-msg, Compiler exceptions,
;;       reflection tests) or require unsupported features (namespaced keys, ::alias/keys)

(ns test.special
  (:use clojure.test))

;; Basic :keys destructuring (works in ClojureWasm)
(deftest basic-keys-destructuring
  (let [m {:a 1 :b 2}]
    (let [{:keys [a b]} m]
      (is (= [1 2] [a b])))))

;; :keys with :or default values
(deftest keys-with-or-destructuring
  (let [m {:a 1 :b 2}]
    (let [{:keys [a b c] :or {c 3}} m]
      (is (= [1 2 3] [a b c])))))

;; :strs destructuring for string keys
(deftest strs-destructuring
  (let [m {"a" 1 "b" 2}]
    (let [{:strs [a b]} m]
      (is (= [1 2] [a b]))))
  (let [{:strs [a b c] :or {c 3}} {"a" 1 "b" 2}]
    (is (= [1 2 3] [a b c]))))

;; :syms destructuring for symbol keys (T17.5.5 — F79 resolved)
(deftest syms-destructuring
  (let [m {'a 1 'b 2}]
    (let [{:syms [a b]} m]
      (is (= [1 2] [a b]))))
  (let [{:syms [a b c] :or {c 3}} {'a 1 'b 2}]
    (is (= [1 2 3] [a b c]))))

;; :as binds the entire map
(deftest as-destructuring
  (let [{:keys [a] :as m} {:a 1 :b 2}]
    (is (= 1 a))
    (is (= {:a 1 :b 2} m))))

;; Combined :keys, :or, :as
(deftest combined-destructuring
  (let [{:keys [a b c] :or {c 3} :as m} {:a 1 :b 2}]
    (is (= 1 a))
    (is (= 2 b))
    (is (= 3 c))
    (is (= {:a 1 :b 2} m))))

;; Sequential destructuring with :as
(deftest sequential-as-destructuring
  (let [[a b :as coll] [1 2 3]]
    (is (= 1 a))
    (is (= 2 b))
    (is (= [1 2 3] coll))))

;; Nested sequential destructuring
(deftest nested-sequential-destructuring
  (let [[a [b c]] [1 [2 3]]]
    (is (= 1 a))
    (is (= 2 b))
    (is (= 3 c))))

;; Rest args in sequential destructuring
(deftest rest-destructuring
  (let [[a & rest] [1 2 3 4]]
    (is (= 1 a))
    (is (= [2 3 4] (vec rest)))))

;; ===========================================================================
;; SKIP: Tests requiring unsupported features
;; ===========================================================================

;; Rest args + map destructuring (T17.5.3 — F67 resolved)
(deftest multiple-keys-in-destructuring
  (let [foo (fn [& {:keys [x]}] x)]
    (is (= (foo :x :b) :b))))

;; SKIP: F60 - empty-list-with-:as-destructuring
;; Requires: {:as x} '() returning {} instead of ()
;; Original: (deftest empty-list-with-:as-destructuring
;;   (let [{:as x} '()]
;;     (is (= {} x))))

;; SKIP: F61 - keywords-in-destructuring
;; Requires: {:keys [:a :b]} - keywords in :keys vector
;; Already tracked in SCI tests

;; SKIP: F62 - namespaced-keywords-in-destructuring
;; Requires: {:keys [:a/b :c/d]} - namespaced keywords in :keys
;; Original: (let [{:keys [:a/b :c/d]} {:a/b 1 :c/d 2}] ...)

;; SKIP: F63 - namespaced-keys-in-destructuring
;; Requires: {:keys [a/b c/d]} - namespaced symbols in :keys
;; Original: (let [{:keys [a/b c/d]} {:a/b 1 :c/d 2}] ...)

;; SKIP: F64 - namespaced-syms-in-destructuring
;; Requires: {:syms [a/b c/d]} - namespaced symbols in :syms
;; Original: (let [{:syms [a/b c/d]} {'a/b 1 'c/d 2}] ...)

;; SKIP: F65 - namespaced-keys-syntax
;; Requires: {:a/keys [b c]} - namespace-qualified :keys
;; Original: (let [{:a/keys [b c]} {:a/b 1 :a/c 2}] ...)

;; SKIP: F66 - namespaced-syms-syntax
;; Requires: {:a/syms [b c]} - namespace-qualified :syms
;; Original: (let [{:a/syms [b c]} {'a/b 1 'a/c 2}] ...)

;; SKIP: keywords-not-allowed-in-let-bindings - JVM exception tests
;; SKIP: namespaced-syms-only-allowed-in-map-destructuring - JVM exception tests
;; SKIP: or-doesnt-create-bindings - JVM exception test
;; SKIP: resolve-keyword-ns-alias-in-destructuring - requires ::alias/key syntax
;; SKIP: quote-with-multiple-args - JVM Compiler exception
;; SKIP: typehints-retained-destructuring - JVM reflection test

(run-tests)
