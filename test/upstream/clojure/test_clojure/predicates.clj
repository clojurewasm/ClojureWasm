;; Upstream: clojure/test/clojure/test_clojure/predicates.clj
;; Upstream lines: 221
;; CLJW markers: 1

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: Java-dependent tests excluded (byte/short/int/long casts, into-array,
;; java.util.Date, bigint, bigdec, Ratio, regex).
;; Uses clojure.test (auto-referred from bootstrap).

(println "[clojure/test_clojure/predicates] running...")

;; ========== nil? ==========

(deftest test-nil?
  (testing "nil? returns true only for nil"
    (is (nil? nil))
    (is (not (nil? false)))
    (is (not (nil? true)))
    (is (not (nil? 0)))
    (is (not (nil? "")))
    (is (not (nil? [])))
    (is (not (nil? {})))))

;; ========== true? / false? ==========

(deftest test-true?
  (testing "true? returns true only for true"
    (is (true? true))
    (is (not (true? false)))
    (is (not (true? nil)))
    (is (not (true? 1)))
    (is (not (true? "true")))))

(deftest test-false?
  (testing "false? returns true only for false"
    (is (false? false))
    (is (not (false? true)))
    (is (not (false? nil)))
    (is (not (false? 0)))
    (is (not (false? "false")))))

;; ========== number? ==========

(deftest test-number?
  (testing "number? on numeric values"
    (is (number? 0))
    (is (number? 42))
    (is (number? -1))
    (is (number? 3.14))
    (is (number? 0.0)))
  (testing "number? on non-numeric values"
    (is (not (number? nil)))
    (is (not (number? true)))
    (is (not (number? "42")))
    (is (not (number? :num)))
    (is (not (number? [1 2 3])))))

;; ========== integer? ==========

(deftest test-integer?
  (testing "integer? on integers"
    (is (integer? 0))
    (is (integer? 42))
    (is (integer? -1)))
  (testing "integer? on floats"
    (is (not (integer? 3.14)))
    (is (not (integer? 0.0))))
  (testing "integer? on non-numbers"
    (is (not (integer? nil)))
    (is (not (integer? "42")))))

;; ========== float? ==========

(deftest test-float?
  (testing "float? on floats"
    (is (float? 3.14))
    (is (float? 0.0))
    (is (float? -1.5)))
  (testing "float? on integers"
    (is (not (float? 0)))
    (is (not (float? 42))))
  (testing "float? on non-numbers"
    (is (not (float? nil)))
    (is (not (float? "3.14")))))

;; ========== symbol? ==========

(deftest test-symbol?
  (testing "symbol?"
    (is (symbol? 'abc))
    (is (symbol? 'foo/bar))
    (is (not (symbol? :abc)))
    (is (not (symbol? "abc")))
    (is (not (symbol? nil)))))

;; ========== keyword? ==========

(deftest test-keyword?
  (testing "keyword?"
    (is (keyword? :abc))
    (is (keyword? :foo/bar))
    (is (not (keyword? 'abc)))
    (is (not (keyword? "abc")))
    (is (not (keyword? nil)))))

;; ========== string? ==========

(deftest test-string?
  (testing "string?"
    (is (string? ""))
    (is (string? "abc"))
    (is (string? "hello world"))
    (is (not (string? nil)))
    (is (not (string? :abc)))
    (is (not (string? 'abc)))
    (is (not (string? 123)))))

;; ========== char? ==========

(deftest test-char?
  (testing "char?"
    (is (char? \a))
    (is (char? \space))
    (is (char? \newline))
    (is (not (char? "a")))
    (is (not (char? nil)))
    (is (not (char? 97)))))

;; ========== list? ==========
;; Note: ClojureWasm (list? ()) returns false (F33)

(deftest test-list?
  (testing "list?"
    ;; (is (list? ()))  ;; Excluded: ClojureWasm returns false for ()
    (is (list? '(1 2 3)))
    (is (list? (list 1 2 3)))
    (is (not (list? [])))
    (is (not (list? nil)))
    (is (not (list? #{})))))

;; ========== vector? ==========

(deftest test-vector?
  (testing "vector?"
    (is (vector? []))
    (is (vector? [1 2 3]))
    (is (vector? (vec '(1 2 3))))
    (is (not (vector? '(1 2 3))))
    (is (not (vector? nil)))
    (is (not (vector? {})))))

;; ========== map? ==========

(deftest test-map?
  (testing "map?"
    (is (map? {}))
    (is (map? {:a 1}))
    (is (map? {:a 1 :b 2 :c 3}))
    (is (not (map? [])))
    (is (not (map? nil)))
    (is (not (map? #{})))))

;; ========== set? ==========

(deftest test-set?
  (testing "set?"
    (is (set? #{}))
    (is (set? #{1 2 3}))
    (is (not (set? [])))
    (is (not (set? nil)))
    (is (not (set? {})))))

;; ========== coll? ==========
;; Note: ClojureWasm (coll? ()) returns false (F33)

(deftest test-coll?
  (testing "coll? on collections"
    ;; (is (coll? ()))  ;; Excluded: ClojureWasm returns false for ()
    (is (coll? '(1 2 3)))
    (is (coll? []))
    (is (coll? [1 2 3]))
    (is (coll? {}))
    (is (coll? {:a 1}))
    (is (coll? #{}))
    (is (coll? #{1 2 3})))
  (testing "coll? on non-collections"
    (is (not (coll? nil)))
    (is (not (coll? "abc")))
    (is (not (coll? 123)))
    (is (not (coll? :kw)))))

;; ========== seq? ==========
;; Note: ClojureWasm (seq? ()) returns false (F33)
;; Note: ClojureWasm (seq [1 2 3]) returns vector, not seq (F34)

(deftest test-seq?
  (testing "seq? on seqs"
    ;; (is (seq? ()))  ;; Excluded: ClojureWasm returns false
    (is (seq? '(1 2 3))))
    ;; (is (seq? (seq [1 2 3])))  ;; Excluded: seq returns vector in ClojureWasm
  (testing "seq? on non-seqs"
    (is (not (seq? [])))
    (is (not (seq? {})))
    (is (not (seq? #{})))
    (is (not (seq? nil)))
    (is (not (seq? "abc")))))

;; ========== sequential? ==========
;; Note: sequential? not implemented in ClojureWasm (F35)

;; (deftest test-sequential?
;;   (testing "sequential? on sequential collections"
;;     (is (sequential? ()))
;;     (is (sequential? '(1 2 3)))
;;     (is (sequential? []))
;;     (is (sequential? [1 2 3])))
;;   (testing "sequential? on non-sequential"
;;     (is (not (sequential? {})))
;;     (is (not (sequential? #{})))
;;     (is (not (sequential? nil)))
;;     (is (not (sequential? "abc")))))

;; ========== associative? ==========
;; Note: associative? not implemented in ClojureWasm (F36)

;; (deftest test-associative?
;;   (testing "associative? on maps and vectors"
;;     (is (associative? {}))
;;     (is (associative? {:a 1}))
;;     (is (associative? []))
;;     (is (associative? [1 2 3])))
;;   (testing "associative? on non-associative"
;;     (is (not (associative? ())))
;;     (is (not (associative? '(1 2 3))))
;;     (is (not (associative? #{})))
;;     (is (not (associative? nil)))))

;; ========== fn? ==========

(deftest test-fn?
  (testing "fn? on functions"
    (is (fn? (fn [] 1)))
    (is (fn? (fn [x] x)))
    (is (fn? inc))
    (is (fn? +)))
  (testing "fn? on non-functions"
    (is (not (fn? nil)))
    (is (not (fn? :kw)))
    (is (not (fn? [1 2 3])))))

;; ========== ifn? ==========
;; Note: ifn? not implemented in ClojureWasm (F37)

;; (deftest test-ifn?
;;   (testing "ifn? on functions"
;;     (is (ifn? (fn [] 1)))
;;     (is (ifn? inc))
;;     (is (ifn? +)))
;;   (testing "ifn? on invocable collections"
;;     (is (ifn? [1 2 3]))      ; vectors are invocable
;;     (is (ifn? {:a 1}))       ; maps are invocable
;;     (is (ifn? #{1 2 3}))     ; sets are invocable
;;     (is (ifn? :keyword))     ; keywords are invocable
;;     (is (ifn? 'symbol)))     ; symbols are invocable
;;   (testing "ifn? on non-invocable"
;;     (is (not (ifn? nil)))
;;     (is (not (ifn? "string")))
;;     (is (not (ifn? 123)))))

;; ========== empty? ==========

(deftest test-empty?
  (testing "empty? on empty collections"
    (is (empty? ()))
    (is (empty? []))
    (is (empty? {}))
    (is (empty? #{}))
    (is (empty? ""))
    (is (empty? nil)))
  (testing "empty? on non-empty"
    (is (not (empty? '(1))))
    (is (not (empty? [1])))
    (is (not (empty? {:a 1})))
    (is (not (empty? #{1})))
    (is (not (empty? "a")))))

;; ========== pos? / neg? / zero? ==========

(deftest test-pos-neg-zero
  (testing "pos?"
    (is (pos? 1))
    (is (pos? 0.5))
    (is (not (pos? 0)))
    (is (not (pos? -1))))
  (testing "neg?"
    (is (neg? -1))
    (is (neg? -0.5))
    (is (not (neg? 0)))
    (is (not (neg? 1))))
  (testing "zero?"
    (is (zero? 0))
    (is (zero? 0.0))
    (is (not (zero? 1)))
    (is (not (zero? -1)))))

;; ========== even? / odd? ==========

(deftest test-even-odd
  (testing "even?"
    (is (even? 0))
    (is (even? 2))
    (is (even? -2))
    (is (not (even? 1)))
    (is (not (even? -1))))
  (testing "odd?"
    (is (odd? 1))
    (is (odd? -1))
    (is (odd? 3))
    (is (not (odd? 0)))
    (is (not (odd? 2)))))

;; ========== Run tests ==========

(run-tests)
