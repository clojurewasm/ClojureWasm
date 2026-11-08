;; `(locking obj body...)` (ADR-0009 lock_state bits + a threadlocal reentrancy
;; held-set, runtime/concurrency/object_monitor.zig). Immediates share one static
;; monitor; nil is refused (clj NPEs). Migrated from test/e2e/phase16_locking.sh,
;; plus the repeated-run stress invariants of phase16_concurrency_stress.sh, which
;; already looped inside ONE process and so lose nothing in a suite.
(ns suites.locking-test
  (:require [clojure.test :refer [deftest is testing]]))

(deftest locking-basics
  (is (= 42 (locking (atom 0) 42)) "locking_basic")
  (is (= 99 (let [a (atom 0)] (locking a (locking a 99)))) "locking_reentrant")
  (is (= 15 (let [a (atom 5) x 10] (locking a (+ x @a)))) "locking_body_env")
  (is (= 42 (locking 5 42)) "locking_immediate")
  (is (thrown-with-msg? ClassCastException #"cannot lock nil" (eval '(locking nil 42)))
      "locking_nil_errors")
  (is (thrown-with-msg? Exception #"locking requires" (eval '(locking (atom 0))))
      "locking_no_body_errors")
  (is (= 99 (let [o (atom 0)]
              (try (locking o (throw (ex-info "x" {}))) (catch Throwable _ :c))
              (locking o 99)))
      "locking_releases_on_throw"))

(deftest locking-mutual-exclusion
  ;; (reset! a (inc @a)) is a NON-atomic read-then-write; only the lock makes
  ;; every increment land.
  (is (= 400 (let [a (atom 0)]
               (run! deref (mapv (fn [_] (future (dotimes [_ 100] (locking a (reset! a (inc @a))))))
                                 (range 4)))
               @a))
      "locking_mutual_exclusion"))

;; --- concurrency stress (memory ordering / lost updates) ---
;; Two real races (atom non-atomic swap!, STM doGet stale read) surfaced only
;; under ReleaseSafe with REPEATED runs, so each invariant loops N times here.
(def ^:private stress-n 20)

(defn- every-iteration? [f] (every? (fn [_] (f)) (range stress-n)))

(defn- fan-out! [f] (run! deref (mapv (fn [_] (future (f))) (range 4))))

(deftest concurrency-stress
  (is (every-iteration? #(let [a (atom 0)] (fan-out! (fn [] (dotimes [_ 100] (swap! a inc)))) (= 400 @a)))
      "stress_atom_swap")
  (is (every-iteration?
       #(let [a (atom 0)]
          (fan-out! (fn [] (dotimes [_ 100]
                             (loop [] (let [o @a] (when-not (compare-and-set! a o (inc o)) (recur)))))))
          (= 400 @a)))
      "stress_atom_cas")
  (is (every-iteration? #(let [c (ref 0)] (fan-out! (fn [] (dotimes [_ 100] (dosync (alter c inc))))) (= 400 @c)))
      "stress_stm_alter")
  (is (every-iteration?
       #(let [a (ref 100) b (ref 0)]
          (fan-out! (fn [] (dotimes [_ 50] (dosync (alter a dec) (alter b inc)))))
          (= [-100 200] [@a @b])))
      "stress_stm_transfer")
  (is (every-iteration? #(let [a (atom 0)] (fan-out! (fn [] (dotimes [_ 100] (locking a (reset! a (inc @a)))))) (= 400 @a)))
      "stress_locking")
  (is (every-iteration? #(let [a (agent 0)] (fan-out! (fn [] (dotimes [_ 100] (send a inc)))) (await a) (= 400 @a)))
      "stress_agent_sends"))
