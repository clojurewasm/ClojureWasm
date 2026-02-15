;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Upstream: clojure/test/clojure/test_clojure/main.clj
;; Upstream lines: 79
;; CLJW markers: 8

; Author: Stuart Halloway


(ns clojure.test-clojure.main
  (:use clojure.test)
  ;; CLJW: removed clojure.test-helper (not available in CW)
  (:require [clojure.main :as main]))

;; CLJW: JVM interop — #'clojure.main/eval-opt not implemented in CW
;; (deftest eval-opt
;;   (testing "evals and prints forms"
;;     (is (= (platform-newlines "2\n4\n") (with-out-str (#'clojure.main/eval-opt "(+ 1 1) (+ 2 2)")))))
;;   (testing "skips printing nils"
;;     (is (= (platform-newlines ":a\n:c\n") (with-out-str (#'clojure.main/eval-opt ":a nil :c")))))
;;   (testing "does not block access to *in* (#299)"
;;     (with-in-str "(+ 1 1)"
;;       (is (= (platform-newlines "(+ 1 1)\n") (with-out-str (#'clojure.main/eval-opt "(read)")))))))

;; CLJW: JVM interop — java.io.PrintWriter not available in CW
;; (defmacro with-err-str ...)
;; (defn run-repl-and-return-err ...)

;argh - test fragility, please fix
;; CLJW: JVM interop — upstream already commented out
;; #_(deftest repl-exception-safety ...)

;; CLJW: JVM interop — Error class, StackTraceElement, Throwable->map not in CW
;; (deftest null-stack-error-reporting
;;   (let [e (doto (Error. "xyz")
;;             (.setStackTrace (into-array java.lang.StackTraceElement nil)))
;;         tr-data (-> e Throwable->map main/ex-triage)]
;;     (is (= tr-data #:clojure.error{:phase :execution, :class 'java.lang.Error, :cause "xyz"}))
;;     (is (= (main/ex-str tr-data) (platform-newlines "Execution error (Error) at (REPL:1).\nxyz\n")))))

;; CLJW: JVM interop — LineNumberingPushbackReader not in CW
;; (defn s->lpr [s] ...)
;; (deftest renumbering-read ...)

;; CLJW: JVM interop — java-loc->source is JVM class name translation
;; (deftest java-loc->source ...)

;; CLJW-ADD: tests for CW-implemented main functions

(deftest test-root-cause
  (testing "root-cause returns innermost exception"
    (let [root (Exception. "root")
          mid (ex-info "mid" {} root)
          outer (ex-info "outer" {} mid)]
      (is (= root (main/root-cause outer)))))
  (testing "root-cause with no nesting returns self"
    (let [e (Exception. "only")]
      (is (= e (main/root-cause e))))))

(deftest test-demunge
  (testing "demunge returns name as-is in CW"
    (is (= "user$eval1" (main/demunge "user$eval1")))
    (is (= "my-fn" (main/demunge "my-fn")))))

(deftest test-repl-prompt
  (testing "repl-prompt prints ns=> format"
    (let [output (with-out-str (main/repl-prompt))]
      (is (clojure.string/includes? output "=>")))))

(deftest test-with-bindings
  (testing "with-bindings preserves *ns*"
    (let [ns-before *ns*]
      (main/with-bindings
        (is (= ns-before *ns*))))))

(deftest test-load-script
  (testing "load-script loads a file"
    (spit "/tmp/cw_main_test_script.clj" "(+ 1 2)")
    (is (= 3 (main/load-script "/tmp/cw_main_test_script.clj")))))

(deftest test-ex-str
  (testing "ex-str formats execution error"
    (let [data {:clojure.error/phase :execution
                :clojure.error/class 'ArithmeticException
                :clojure.error/cause "Divide by zero"}]
      (is (clojure.string/includes? (main/ex-str data) "Execution error"))
      (is (clojure.string/includes? (main/ex-str data) "Divide by zero")))))

(deftest test-repl-requires
  (testing "repl-requires is a sequence of lib specs"
    (is (sequential? main/repl-requires))
    (is (pos? (count main/repl-requires)))))

;; CLJW-ADD: test runner invocation
(run-tests)
