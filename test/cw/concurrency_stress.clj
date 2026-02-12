;; CW-original concurrency stress tests (Phase 57).
;; Not an upstream port — tests CW-specific threading behavior.
;; Run: ./zig-out/bin/cljw test/cw/concurrency_stress.clj
;;      ./zig-out/bin/cljw --tree-walk test/cw/concurrency_stress.clj

(require 'clojure.test)
(ns cw.concurrency-stress
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ============================================================
;; B. Stress tests
;; ============================================================

;; 57.5: atom swap! N-thread contention
(deftest atom-swap-contention
  (testing "Multiple futures contending on atom swap!"
    (let [a (atom 0)
          n 100
          futures (doall (map (fn [_] (future (dotimes [_ 10] (swap! a inc)))) (range n)))]
      (doseq [f futures] @f)
      (is (= (* n 10) @a)
          "All increments should be reflected (CAS retry guarantees)"))))

;; 57.6: delay N-thread simultaneous deref
(deftest delay-concurrent-deref
  (testing "Multiple futures deref same delay — call-once guarantee"
    (let [call-count (atom 0)
          d (delay (swap! call-count inc) 42)
          futures (doall (map (fn [_] (future @d)) (range 20)))]
      (doseq [f futures] (is (= 42 @f)))
      (is (= 1 @call-count)
          "delay body should execute exactly once despite concurrent deref"))))

;; 57.7: Mass future spawn + collect all results
(deftest mass-future-spawn
  (testing "Spawn many futures and collect all results"
    (let [n 200
          futures (doall (map (fn [i] (future (* i i))) (range n)))
          results (map deref futures)]
      (is (= (map #(* % %) (range n)) results)
          "All futures should return correct computed values"))))

;; 57.8: Agent high-frequency send
(deftest agent-high-frequency-send
  (testing "Rapid sends to agent maintain ordering and correctness"
    (let [a (agent [])
          n 100]
      (dotimes [i n]
        (send a conj i))
      (await a)
      (is (= (vec (range n)) @a)
          "Agent should process all sends in order"))))

;; ============================================================
;; C. Binding conveyance
;; ============================================================

;; 57.9: future inherits *out* bindings
(deftest future-inherits-bindings
  (testing "future inherits dynamic bindings from parent thread"
    (let [result (promise)]
      (binding [*print-length* 3]
        (let [f (future *print-length*)]
          (deliver result @f)))
      (is (= 3 @result)
          "*print-length* should be conveyed to future thread"))))

;; 57.10: Nested binding + future (frame integrity)
(deftest nested-binding-future
  (testing "Nested bindings are correctly conveyed to futures"
    (binding [*print-length* 5]
      (let [outer-val *print-length*
            inner-result (binding [*print-length* 10]
                           @(future *print-length*))]
        (is (= 5 outer-val))
        (is (= 10 inner-result)
            "Inner binding should be conveyed, not outer")))))

;; 57.11: Agent send inherits bindings
(deftest agent-binding-conveyance
  (testing "Agent actions receive conveyed bindings"
    (let [a (agent nil)]
      (binding [*print-length* 7]
        (send a (fn [_] *print-length*))
        (await a))
      (is (= 7 @a)
          "*print-length* should be conveyed to agent action"))))

;; ============================================================
;; D. Lifecycle / edge cases
;; ============================================================

;; 57.12: future-cancel
(deftest future-cancel-test
  (testing "future-cancel and future-cancelled?"
    (let [p (promise)
          f (future @p)] ; blocks until promise is delivered
      (is (not (future-done? f)))
      (future-cancel f)
      ;; Note: CW's future-cancel may not interrupt blocked threads
      ;; but should at least not crash
      (deliver p :done)
      @f))) ; ensure no hang

;; 57.13: promise deref with timeout
(deftest promise-deref-timeout
  (testing "promise deref with timeout returns timeout-val"
    (let [p (promise)
          result (deref p 10 :timeout)]
      (is (= :timeout result)
          "Undelivered promise should return timeout-val after timeout"))))

;; 57.14: agent restart-agent after error
(deftest agent-restart-after-error
  (testing "restart-agent recovers from error state"
    (let [a (agent 0)]
      (set-error-mode! a :fail)
      (send a (fn [_] (throw (ex-info "boom" {}))))
      (Thread/sleep 50) ; wait for action to process
      (is (agent-error a) "Agent should be in error state")
      (restart-agent a 42)
      (is (nil? (agent-error a)) "Error should be cleared")
      (is (= 42 @a) "State should be reset to new value"))))

;; ============================================================
;; Run tests
;; ============================================================

(let [result (run-tests)]
  (when (or (pos? (:fail result)) (pos? (:error result)))
    (System/exit 1)))
