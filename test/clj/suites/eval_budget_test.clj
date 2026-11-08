;; cljw.eval/with-budget (ADR-0125, D-355 Path A): an in-process scoped budget
;; whose breach is RECOVERED as a value, so a long-lived server survives a
;; runaway eval. The process-global env budgets (CLJW_EVAL_MAX_STEPS /
;; CLJW_EVAL_DEADLINE_MS / CLJW_EVAL_MAX_HEAP_MB) kill the process uncatchably
;; and stay in test/e2e/phase16_eval_budget.sh.
;;
;; Migrated from that script's with-budget cases; marker names kept.
(ns suites.eval-budget-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest with-budget-success
  (is (= 3 (cljw.eval/with-budget {:max-steps 1000000} (fn [] (+ 1 2))))
      "with-budget-success: the thunk's value comes back"))

(deftest with-budget-recovers-and-survives
  (testing "a step breach answers the exhausted marker, not a throw"
    (is (= :steps (:cljw.eval/exhausted
                   (cljw.eval/with-budget {:max-steps 100000} (fn [] (loop [] (recur))))))))
  (testing "a deadline breach answers the exhausted marker"
    (is (= :deadline (:cljw.eval/exhausted
                      (cljw.eval/with-budget {:deadline-ms 100} (fn [] (loop [] (recur))))))))
  (testing "the caller keeps running after a breach"
    (is (= 42 (+ 40 2)))))

(deftest with-budget-heap-recovers
  ;; The heap ceiling is measured against the live heap, which in the shared
  ;; suite image is already populated: the probe allocates far past any
  ;; plausible image size so the cap trips on the allocation itself.
  (is (= :heap (:cljw.eval/exhausted
                (cljw.eval/with-budget {:max-heap-mb 64} (fn [] (vec (range 100000000))))))
      "with-budget-recovers-and-survives (heap)"))
