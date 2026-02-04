;; Upstream: clojure/test/clojure/test_clojure/atoms.clj
;; Upstream lines: 63
;; CLJW markers: 3

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;;Author: Frantisek Sodomka

(ns clojure.test-clojure.atoms
  (:use clojure.test))

; http://clojure.org/atoms

; atom
; deref, @-reader-macro
; swap! reset!
; compare-and-set!

(deftest swap-vals-returns-old-value
  (let [a (atom 0)]
    (is (= [0 1] (swap-vals! a inc)))
    (is (= [1 2] (swap-vals! a inc)))
    (is (= 2 @a))))

(deftest deref-swap-arities
  (binding [*warn-on-reflection* true]
    (let [a (atom 0)]
      (is (= [0 1] (swap-vals! a + 1)))
      (is (= [1 3] (swap-vals! a + 1 1)))
      (is (= [3 6] (swap-vals! a + 1 1 1)))
      (is (= [6 10] (swap-vals! a + 1 1 1 1)))
      (is (= 10 @a)))))

(deftest deref-reset-returns-old-value
  (let [a (atom 0)]
    (is (= [0 :b] (reset-vals! a :b)))
    ;; CLJW: 45M BigDecimal literal not supported, using integer 45
    (is (= [:b 45] (reset-vals! a 45)))
    (is (= 45 @a))))

(deftest reset-on-deref-reset-equality
  (let [a (atom :usual-value)]
    (is (= :usual-value (reset! a (first (reset-vals! a :almost-never-seen-value)))))))

;; CLJW: JVM interop — java.util.function.Supplier/IntSupplier/etc not applicable
;; (deftest atoms-are-suppliers
;;   (let [a (atom 10)]
;;     (is (instance? java.util.function.Supplier a))
;;     ...))

;; CLJW-ADD: test runner invocation
(run-tests)
