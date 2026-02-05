;; Upstream: clojure/test/clojure/test_clojure/evaluation.clj
;; Upstream lines: 226
;; CLJW markers: 8

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.


;;  Tests for the Clojure functions documented at the URL:
;;
;;    http://clojure.org/Evaluation
;;
;;  by J. McConnell
;;  Created 22 October 2008

;; CLJW: ns simplified — removed test-helper import
(ns clojure.test-clojure.evaluation
  (:use clojure.test))

;; CLJW: test-that macro removed — uses resolve/the-ns/ns-meta which require full ns introspection
;; CLJW: throws-with-msg macro removed — uses .getCause, class, Java exceptions

(deftest Eval
  (is (= (eval '(+ 1 2 3)) 6))
  (is (= (eval '(list 1 2 3)) '(1 2 3)))
  ;; CLJW: (eval '(list + 1 2 3)) removed — requires fn equality comparison
  (is (= (eval (list '+ 1 2 3)) 6)))

;;; Literals tests ;;;

(deftest Literals
  ; Strings, numbers, characters, nil and keywords should evaluate to themselves
  (is (= (eval "test") "test"))
  (is (= (eval "test
                        multi-line
                        string")
         "test
                        multi-line
                        string"))
  (is (= (eval 1) 1))
  (is (= (eval 1.0) 1.0))
  (is (= (eval 1.123456789) 1.123456789))
  ;; CLJW: 1/2 (ratio), 1M (BigDecimal) — not supported
  (is (= (eval 999999999999999999) 999999999999999999))
  (is (= (eval \a) \a))
  (is (= (eval \newline) \newline))
  (is (= (eval nil) nil))
  (is (= (eval :test) :test))
  ; Boolean literals
  (is (= (eval true) true))
  (is (= (eval false) false)))

;; CLJW: SymbolResolution skipped — requires Compiler$CompilerException, in-ns, java.lang.Class
;; CLJW: Metadata test skipped — requires defstruct/struct

;;; Collections tests ;;;
(def x 1)
(def y 2)

(deftest Collections
  (is (= (eval '[x y 3]) [1 2 3]))
  (is (= (eval '{:x x :y y :z 3}) {:x 1 :y 2 :z 3}))

  (is (= (eval '()) ()))
  (is (empty? (eval ())))
  (is (= (eval (list)) ())))

(deftest Macros)

(deftest Loading)

;; CLJW-ADD: test runner invocation
(run-tests)
