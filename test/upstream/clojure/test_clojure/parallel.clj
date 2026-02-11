;; Upstream: clojure/test/clojure/test_clojure/parallel.clj
;; Upstream lines: 41
;; CLJW markers: 2

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka


(ns clojure.test-clojure.parallel
  (:use clojure.test))

;; !! Tests for the parallel library will be in a separate file clojure_parallel.clj !!

; future-call
; future
; pmap
; pcalls
; pvalues

;; pmap
;;
(deftest pmap-does-its-thing
  ;; regression fixed in r1218; was OutOfMemoryError
  (is (= '(1) (pmap inc [0]))))

(def ^:dynamic *test-value* 1)

(deftest future-fn-properly-retains-conveyed-bindings
  (let [a (atom [])]
    (binding [*test-value* 2]
      @(future (dotimes [_ 3]
                 ;; we need some binding to trigger binding pop
                 (binding [*print-dup* false]
                   (swap! a conj *test-value*))))
      (is (= [2 2 2] @a)))))

;; CLJW-ADD: additional concurrency tests for Phase 48 features

(deftest test-future-basic
  (testing "future returns a deref-able value"
    (let [f (future (+ 1 2))]
      (is (= 3 @f))))
  (testing "future? predicate"
    (is (future? (future nil)))
    (is (not (future? 42)))
    (is (not (future? (atom 0)))))
  (testing "future-done? after deref"
    (let [f (future (+ 10 20))]
      (is (= 30 @f))
      (is (future-done? f)))))

(deftest test-future-call-basic
  (let [f (future-call (fn [] (* 6 7)))]
    (is (= 42 @f))
    (is (future-done? f))))

(deftest test-promise-basic
  (testing "promise creation and delivery"
    (let [p (promise)]
      (is (not (realized? p)))
      (deliver p :hello)
      (is (realized? p))
      (is (= :hello @p))))
  (testing "deliver returns the promise"
    (let [p (promise)]
      (is (= p (deliver p 1)))))
  (testing "double deliver is no-op"
    (let [p (promise)]
      (deliver p :first)
      (deliver p :second)
      (is (= :first @p))))
  (testing "promise can hold nil"
    (let [p (promise)]
      (deliver p nil)
      (is (realized? p))
      (is (nil? @p)))))

(deftest test-realized-predicate
  (testing "realized? on delay"
    (let [d (delay 42)]
      (is (not (realized? d)))
      (is (= 42 @d))
      (is (realized? d))))
  (testing "realized? on future"
    (let [f (future 42)]
      (is (= 42 @f))
      (is (realized? f))))
  (testing "realized? on promise"
    (let [p (promise)]
      (is (not (realized? p)))
      (deliver p 42)
      (is (realized? p)))))

(deftest test-pmap-multi-coll
  (testing "pmap with multiple collections"
    (is (= '(5 7 9) (pmap + [1 2 3] [4 5 6]))))
  (testing "pmap with unequal lengths"
    (is (= '(5 7) (pmap + [1 2 3] [4 5])))))

(deftest test-pcalls-basic
  (is (= [3 7 11] (into [] (pcalls #(+ 1 2) #(+ 3 4) #(+ 5 6))))))

(deftest test-pvalues-basic
  (is (= [3 7 11] (into [] (pvalues (+ 1 2) (+ 3 4) (+ 5 6))))))

(deftest test-thread-sleep
  (let [start (System/nanoTime)]
    (Thread/sleep 50)
    (let [elapsed (/ (- (System/nanoTime) start) 1000000)]
      (is (>= elapsed 40)))))

(deftest test-shutdown-agents-idempotent
  ;; shutdown-agents should be safe to call
  (is (nil? (shutdown-agents))))

;; CLJW-ADD: test runner invocation
(run-tests)
(shutdown-agents)
