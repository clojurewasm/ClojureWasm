(ns suites.future-methods-test
  (:require [clojure.test :refer [deftest is testing]])
  (:import [java.util.concurrent Future]))

(deftest get-agrees-with-deref
  (testing "completed values"
    (is (= 3 (.get (future (+ 1 2))))) ; get_value
    (is (= [42 42]
           (let [f (future (* 6 7))]
             [(.get f) @f]))) ; get_matches_deref
    (is (nil? (.get (future nil)))))) ; get_nil_body

(deftest completion-status
  (testing "isDone follows every terminal state"
    (is (= true
           (let [f (future 1)]
             @f
             (.isDone f)))) ; isDone_after_value
    (is (= [true true]
           (let [f (future 1)]
             @f
             [(.isDone f) (realized? f)]))) ; isDone_matches_realized
    (is (= true
           (let [f (future (Thread/sleep 5000))]
             (.cancel f true)
             (.isDone f))))) ; isDone_after_cancel
  (testing "isCancelled agrees with future-cancelled?"
    (is (= [false false]
           (let [f (future 1)]
             @f
             [(.isCancelled f) (future-cancelled? f)]))))) ; isCancelled_false_when_completed

(deftest cancellation-contract
  (testing "only the first pending cancellation wins"
    (is (= [true true]
           (let [f (future (Thread/sleep 5000))]
             [(.cancel f true) (.isCancelled f)]))) ; cancel_pending_wins
    (is (= [true false]
           (let [f (future (Thread/sleep 5000))]
             [(.cancel f true) (.cancel f true)]))) ; cancel_twice_second_loses
    (is (= false
           (let [f (future 1)]
             @f
             (.cancel f true))))) ; cancel_realised_returns_false
  (testing "AD-065: mayInterruptIfRunning is accepted but ignored"
    (is (= [true true]
           (let [f (future (Thread/sleep 5000))]
             [(.cancel f false) (.isCancelled f)]))) ; cancel_flag_is_ignored_ad065
    (is (= true
           (let [f (future (Thread/sleep 5000))]
             (.cancel f)))))) ; cancel_arity_1_accepted

(deftest terminal-errors
  (testing "cancelled get throws CancellationException"
    (is (= :cancellation
           (let [f (future (Thread/sleep 5000))]
             (.cancel f true)
             (try
               (.get f)
               :no-throw
               (catch java.util.concurrent.CancellationException _
                 :cancellation)))))) ; get_cancelled_throws_cancellation
  (testing "failed get rethrows the original exception"
    (is (= :boom
           (let [f (future (throw (ex-info "boom" {:a 1})))]
             (try
               (.get f)
               :no-throw
               (catch Exception e
                 (keyword (.getMessage e))))))))) ; get_rethrows_original

(deftest timed-get-contract
  (testing "value completes before deadline"
    (is (= 42
           (.get (future (+ 20 22))
                 2000
                 java.util.concurrent.TimeUnit/MILLISECONDS)))) ; get_timed_returns_value
  (testing "deadline throws TimeoutException"
    (let [f (future (Thread/sleep 5000))]
      (try
        (is (= :timeout
               (try
                 (.get f 50 java.util.concurrent.TimeUnit/MILLISECONDS)
                 :no-throw
                 (catch java.util.concurrent.TimeoutException _
                   :timeout)))) ; get_timed_throws_timeout
        (finally
          (future-cancel f)))))
  (testing "TimeoutException remains an Exception"
    (let [f (future (Thread/sleep 5000))]
      (try
        (is (= :caught
               (try
                 (.get f 50 java.util.concurrent.TimeUnit/MILLISECONDS)
                 :no-throw
                 (catch Exception _
                   :caught)))) ; timeout_is_an_exception
        (finally
          (future-cancel f)))))
  (testing "timed deref still returns its default"
    (let [f (future (Thread/sleep 5000))]
      (try
        (is (= :fallback (deref f 50 :fallback))) ; timed_deref_still_returns_default
        (finally
          (future-cancel f)))))
  (testing "invalid time unit is rejected"
    (is (= :threw
           (let [f (future 1)]
             (try
               (.get f 10 :not-a-unit)
               :no-throw
               (catch Exception _
                 :threw))))))) ; get_timed_bad_unit

(deftest future-is-reifiable
  (testing "fully qualified interface spelling"
    (is (= [99 true false false]
           (let [f (reify java.util.concurrent.Future
                     (get [_] 99)
                     (get [_ _t _u] 99)
                     (isDone [_] true)
                     (isCancelled [_] false)
                     (cancel [_ _] false))]
             [(.get f) (.isDone f) (.isCancelled f) (.cancel f true)])))) ; reify_future_get
  (testing "bare imported interface spelling"
    (is (= [7 true]
           (let [f (reify Future
                     (get [_] 7)
                     (isDone [_] true)
                     (isCancelled [_] false)
                     (cancel [_ _] false))]
             [(.get f) (.isDone f)]))))) ; reify_future_bare_spelling

(deftest native-future-class-identity
  (let [f (future 1)]
    (is (= "Future" (str (class f)))) ; class_name
    @f))
