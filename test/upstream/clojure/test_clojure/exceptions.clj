;; CLJW-ADD: Tests for CW exception handling
;; ex-info, ex-data, ex-message, throw/catch, exception hierarchy

(ns clojure.test-clojure.exceptions
  (:require [clojure.test :refer [deftest is testing run-tests]]))

;; ========== ex-info / ex-data ==========

(deftest test-ex-info-basic
  (testing "ex-info creates exception with message and data"
    (let [e (ex-info "boom" {:code 42})]
      (is (= "boom" (ex-message e)))
      (is (= {:code 42} (ex-data e)))))
  (testing "ex-info with cause"
    (let [cause (ex-info "root" {})
          e (ex-info "wrapper" {:wrapped true} cause)]
      (is (= "wrapper" (ex-message e)))
      (is (= {:wrapped true} (ex-data e)))
      (is (= "root" (ex-message (ex-cause e))))))
  ;; CLJW: Exception. creates ex-info-like maps in CW, so ex-data returns {}
  (testing "ex-data returns empty map for plain Exception"
    (is (= {} (ex-data (Exception. "plain"))))))

;; ========== throw / catch ==========

(deftest test-throw-catch
  (testing "basic throw and catch"
    (is (thrown? Exception (throw (Exception. "test")))))
  (testing "catch with binding"
    (is (= "caught"
           (try
             (throw (Exception. "fail"))
             (catch Exception e "caught")))))
  (testing "ex-message in catch"
    (is (= "hello"
           (try
             (throw (Exception. "hello"))
             (catch Exception e (ex-message e))))))
  (testing "ex-info in throw/catch"
    (is (= {:key "val"}
           (try
             (throw (ex-info "boom" {:key "val"}))
             (catch Exception e (ex-data e)))))))

;; ========== try / finally ==========

(deftest test-try-finally
  (testing "finally always runs"
    (let [a (atom 0)]
      (try
        (reset! a 1)
        (finally
          (reset! a 2)))
      (is (= 2 @a))))
  (testing "finally runs even on exception"
    (let [a (atom 0)]
      (try
        (throw (Exception. "boom"))
        (catch Exception e nil)
        (finally
          (reset! a 99)))
      (is (= 99 @a)))))

;; ========== nested exceptions ==========

(deftest test-nested-exceptions
  (testing "nested try/catch"
    (is (= "inner"
           (try
             (try
               (throw (Exception. "inner"))
               (catch Exception e (ex-message e)))
             (catch Exception e "outer")))))
  (testing "rethrow"
    (is (= "original"
           (try
             (try
               (throw (Exception. "original"))
               (catch Exception e (throw e)))
             (catch Exception e (ex-message e)))))))

;; ========== Exception. constructor ==========

(deftest test-exception-constructor
  (testing "Exception with message"
    (let [e (Exception. "test message")]
      (is (= "test message" (ex-message e)))))
  (testing "Exception with message and cause"
    (let [cause (Exception. "cause")
          e (Exception. "effect" cause)]
      (is (= "effect" (ex-message e)))
      (is (= "cause" (ex-message (ex-cause e)))))))

(run-tests)
