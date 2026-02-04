;; Upstream: clojure/test/clojure/test_clojure/delays.clj
;; Upstream lines: 89
;; CLJW markers: 6

;; CLJW: removed (:import [java.util.concurrent CyclicBarrier])
(ns clojure.test-clojure.delays
  (:use clojure.test))

(deftest calls-once
  (let [a (atom 0)
        d (delay (swap! a inc))]
    (is (= 0 @a))
    (is (= 1 @d))
    (is (= 1 @d))
    (is (= 1 @a))))

;; CLJW: JVM interop — calls-once-in-parallel requires Thread/CyclicBarrier

;; CLJW: adapted from upstream — Exception. → string throw, instance? → some?
(deftest saves-exceptions
  (let [f #(do (throw "broken")
               1)
        d (delay (f))
        try-call #(try
                    @d
                    (catch Exception e e))
        first-result (try-call)]
    (is (some? first-result))                        ;; CLJW: was (instance? Exception first-result)
    (is (identical? first-result (try-call)))))       ;; cached exception identity

;; CLJW: JVM interop — saves-exceptions-in-parallel requires Thread/CyclicBarrier
;; CLJW: JVM interop — delays-are-suppliers requires java.util.function.Supplier

;; CLJW-ADD: test runner invocation
(run-tests)
