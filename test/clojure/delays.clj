;; Ported from clojure/test_clojure/delays.clj
;; SKIP: calls-once-in-parallel (Thread, CyclicBarrier — JVM)
;; SKIP: saves-exceptions (try/catch, throw — needs exception support)
;; SKIP: saves-exceptions-in-parallel (Thread — JVM)
;; SKIP: delays-are-suppliers (java.util.function.Supplier — JVM)

(ns clojure.test-clojure.delays
  (:use clojure.test))

;; === calls-once (upstream verbatim) ===

(deftest calls-once
  (let [a (atom 0)
        d (delay (swap! a inc))]
    (is (= 0 @a))
    (is (= 1 @d))
    (is (= 1 @d))
    (is (= 1 @a))))

;; === delay? ===

(deftest test-delay-pred
  (let [d (delay 42)]
    (is (= true (delay? d)))
    (is (= false (delay? 42)))
    (is (= false (delay? [1 2 3])))
    (is (= false (delay? {:a 1})))))

;; === force ===

(deftest test-force
  (testing "force on delay evaluates it"
    (let [d (delay (+ 10 20))]
      (is (= 30 (force d)))
      (is (= true (realized? d)))))
  (testing "force on non-delay returns value unchanged"
    (is (= 42 (force 42)))
    (is (= "hello" (force "hello")))
    (is (= nil (force nil)))))

;; === realized? ===

(deftest test-realized
  (let [d (delay (+ 1 2))]
    (is (= false (realized? d)))
    (force d)
    (is (= true (realized? d)))))

;; === delay caching ===

(deftest test-delay-caches
  (testing "delay body is only evaluated once"
    (let [counter (atom 0)
          d (delay (swap! counter inc) :done)]
      (is (= :done @d))
      (is (= :done @d))
      (is (= :done @d))
      (is (= 1 @counter)))))

;; === delay with side effects ===

(deftest test-delay-side-effects
  (let [log (atom [])
        d (delay (swap! log conj :evaluated) 42)]
    (is (= [] @log))
    (is (= 42 @d))
    (is (= [:evaluated] @log))
    (is (= 42 @d))
    (is (= [:evaluated] @log))))

;; Run tests
(run-tests)
