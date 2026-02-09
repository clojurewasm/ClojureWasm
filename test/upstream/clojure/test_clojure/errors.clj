;; Upstream: clojure/test/clojure/test_clojure/errors.clj
;; Upstream lines: 119
;; CLJW markers: 12

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Tests for error handling and messages

(ns clojure.test-clojure.errors
  ;; CLJW: removed (:import clojure.lang.ArityException) — no Java class system
  (:use clojure.test))

(defn f0 [] 0)

(defn f1 [a] a)

;; CLJW: f2:+><->!#%&*|b skipped — demunge testing requires JVM name mangling

(defmacro m0 [] `(identity 0))

(defmacro m1 [a] `(inc ~a))

;; CLJW: m2 macro skipped — (assoc) arity test needs ArityException .-actual field (JVM interop)

(deftest arity-exception
  ;; CLJW: adapted — thrown-with-msg?/ArityException → try/catch + thrown?
  ;; Testing that arity errors are thrown (message format differs from JVM)
  (is (thrown? Exception (f0 1)))
  (is (thrown? Exception (f1)))
  ;; CLJW: macroexpand arity tests and .-actual field tests skipped — JVM interop
  )

;; CLJW: compile-error-examples skipped — Long/parseLong, .jump JVM interop
;; CLJW: assert-arg-messages skipped — CompilerException JVM class

(deftest extract-ex-data
  (try
    (throw (ex-info "example error" {:foo 1}))
    (catch Exception t
      (is (= {:foo 1} (ex-data t)))))
  ;; CLJW: adapted — RuntimeException. constructor → ex-info without data
  (is (nil? (ex-data (try (throw (ex-info "example non ex-data" {}))
                          (catch Exception e (ex-message e)))))))

;; CLJW: Throwable->map-test skipped — Throwable->map, Exception chain, .setStackTrace JVM interop

(deftest ex-info-allows-nil-data
  (is (= {} (ex-data (ex-info "message" nil))))
  ;; CLJW: adapted — Throwable. → ex-info for cause
  (is (= {} (ex-data (ex-info "message" nil (ex-info "cause" {}))))))

;; CLJW: ex-info-arities-construct-equivalent-exceptions skipped — .getMessage/.getData/.getCause JVM interop

;; CLJW-ADD: test runner invocation
(run-tests)
