;; Upstream: clojure/test/clojure/test_clojure/vars.clj
;; Upstream lines: 109
;; CLJW markers: 8

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka, Stephen C. Gilardi


(ns clojure.test-clojure.vars
  (:use clojure.test))

; http://clojure.org/vars

; def
; defn defn- defonce

; declare intern binding find-var var

(def ^:dynamic a)
(deftest test-binding
  (are [x y] (= x y)
    (eval `(binding [a 4] a)) 4     ; regression in Clojure SVN r1370
    ))

; var-get var-set alter-var-root [var? (predicates.clj)]
; with-in-str with-out-str
; with-open

;; CLJW: JVM interop — test-with-local-vars requires clojure.lang.Var/create, pushThreadBindings
;; CLJW: JVM interop — test-with-precision requires BigDecimal (with-precision, 10 assertions)
;; CLJW: JVM interop — test-settable-math-context requires java.math.MathContext
;; CLJW: JVM interop — test-with-redefs-fn requires promise, Thread
;; CLJW: JVM interop — test-with-redefs requires promise, Thread
;; CLJW: JVM interop — test-with-redefs-throw requires promise, Thread
;; CLJW: JVM interop — test-with-redefs-inside-binding requires with-redefs
;; CLJW: JVM interop — test-vars-apply-lazily requires future, deref-with-timeout

;; CLJW-ADD: test runner invocation
(run-tests)
