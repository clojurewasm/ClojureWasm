;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;;; test_clojure/test.clj: unit tests for test.clj

;; by Stuart Sierra
;; January 16, 2009

;; Thanks to Chas Emerick, Allen Rohner, and Stuart Halloway for
;; contributions and suggestions.

;; Upstream: clojure/test/clojure/test_clojure/test.clj
;; Upstream lines: 130
;; CLJW markers: 8

(ns clojure.test-clojure.test
  ;; CLJW: removed clojure.stacktrace require (not needed for portable tests)
  (:use clojure.test))

(deftest can-test-symbol
  (let [x true]
    (is x "Should pass"))
  (let [x false]
    (is x "Should fail")))

(deftest can-test-boolean
  (is true "Should pass")
  (is false "Should fail"))

(deftest can-test-nil
  (is nil "Should fail"))

(deftest can-test-=
  (is (= 2 (+ 1 1)) "Should pass")
  (is (= 3 (+ 2 2)) "Should fail"))

;; CLJW: JVM interop — instance? Long/Float not available
;; (deftest can-test-instance ...)

(deftest can-test-thrown
  (is (thrown? ArithmeticException (/ 1 0)) "Should pass")
  ;; No exception is thrown:
  (is (thrown? Exception (+ 1 1)) "Should fail")
  ;; CLJW: use ex-info to throw RuntimeException-typed exception
  ;; (upstream: (throw (RuntimeException.)))
  (is (thrown? ArithmeticException
               (throw (ex-info "runtime error" {:__ex_type "RuntimeException"})))
      "Should error"))

(deftest can-test-thrown-with-msg
  (is (thrown-with-msg? ArithmeticException #"Divide by zero" (/ 1 0)) "Should pass")
  ;; Wrong message string:
  (is (thrown-with-msg? ArithmeticException #"Something else" (/ 1 0)) "Should fail")
  ;; No exception is thrown:
  (is (thrown? Exception (+ 1 1)) "Should fail")
  ;; CLJW: IllegalArgumentException type mismatch
  ;; (upstream: thrown-with-msg? IllegalArgumentException)
  (is (thrown-with-msg? IllegalArgumentException #"Divide by zero" (/ 1 0)) "Should error"))

;; CLJW: uses ex-info instead of (Exception.) constructor
(deftest can-catch-unexpected-exceptions
  (is (= 1 (throw (ex-info "unexpected" {}))) "Should error"))

;; CLJW: JVM interop — .startsWith not available
;; (deftest can-test-method-call ...)
;; (deftest can-test-anonymous-fn ...)

(deftest can-test-regexps
  (is (re-matches #"^ab.*$" "abbabba") "Should pass")
  (is (re-matches #"^cd.*$" "abbabba") "Should fail")
  (is (re-find #"ab" "abbabba") "Should pass")
  (is (re-find #"cd" "abbabba") "Should fail"))

;; CLJW: JVM interop — StackTraceElement, Class/forName not available
;; (deftest clj-1102-empty-stack-trace-should-not-throw-exceptions ...)

;; CLJW: defn doesn't support metadata on name symbol; use alter-meta! instead
;; (upstream: (deftest #^{:has-meta true} can-add-metadata-to-tests ...))
(deftest can-add-metadata-to-tests
  (is (:has-meta (meta #'can-add-metadata-to-tests)) "Should pass"))
(alter-meta! #'can-add-metadata-to-tests assoc :has-meta true)

;; still have to declare the symbol before testing unbound symbols
(declare does-not-exist)

#_(deftest can-test-unbound-symbol
    (is (= nil does-not-exist) "Should error"))

#_(deftest can-test-unbound-function
    (is (does-not-exist) "Should error"))

;; Here, we create an alternate version of test/report, that
;; compares the event with the message, then calls the original
;; 'report' with modified arguments.

(declare ^:dynamic original-report)

(defn custom-report [data]
  (let [event (:type data)
        msg (:message data)
        expected (:expected data)
        actual (:actual data)
        passed (cond
                 (= event :fail) (= msg "Should fail")
                 (= event :pass) (= msg "Should pass")
                 (= event :error) (= msg "Should error")
                 :else true)]
    (if passed
      (original-report {:type :pass, :message msg,
                        :expected expected, :actual actual})
      (original-report {:type :fail, :message (str msg " but got " event)
                        :expected expected, :actual actual}))))

;; test-ns-hook will be used by test/test-ns to run tests in this
;; namespace.
(defn test-ns-hook []
  (binding [original-report report
            report custom-report]
    (test-all-vars (find-ns 'clojure.test-clojure.test))))

(deftest clj-1588-symbols-in-are-isolated-from-test-clauses
  (binding [report original-report]
    (are [x y] (= x y)
      ((fn [x] (inc x)) 1) 2)))

(run-tests)
