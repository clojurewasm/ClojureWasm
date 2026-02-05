;; Upstream: clojure/test/clojure/test_clojure/special.clj
;; Upstream lines: 107
;; CLJW markers: 7

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

; Author: Frantisek Sodomka

;;
;;  Test special forms, macros and metadata
;;

;; CLJW: ns form simplified — removed test-helper require
(ns clojure.test-clojure.special
  (:use clojure.test))

; http://clojure.org/special_forms

; let, letfn
; quote
; var
; fn

(deftest multiple-keys-in-destructuring
  (let [foo (fn [& {:keys [x]}] x)
        bar (fn [& options] (apply foo :x :b options))]
    (is (= (bar) :b))
    (is (= (bar :x :a) :a))))

(deftest empty-list-with-:as-destructuring
  (let [{:as x} '()]
    (is (= {} x))))

(deftest keywords-in-destructuring
  (let [m {:a 1 :b 2}]
    (let [{:keys [:a :b]} m]
      (is (= [1 2] [a b])))
    (let [{:keys [:a :b :c] :or {c 3}} m]
      (is (= [1 2 3] [a b c])))))

(deftest namespaced-keywords-in-destructuring
  (let [m {:a/b 1 :c/d 2}]
    (let [{:keys [:a/b :c/d]} m]
      (is (= [1 2] [b d])))
    (let [{:keys [:a/b :c/d :e/f] :or {f 3}} m]
      (is (= [1 2 3] [b d f])))))

(deftest namespaced-keys-in-destructuring
  (let [m {:a/b 1 :c/d 2}]
    (let [{:keys [a/b c/d]} m]
      (is (= [1 2] [b d])))
    (let [{:keys [a/b c/d e/f] :or {f 3}} m]
      (is (= [1 2 3] [b d f])))))

(deftest namespaced-syms-in-destructuring
  (let [{:syms [a/b c/d e/f] :or {f 3}} {'a/b 1 'c/d 2}]
    (is (= [1 2 3] [b d f]))))

(deftest namespaced-keys-syntax
  (let [{:a/keys [b c d] :or {d 3}} {:a/b 1 :a/c 2}]
    (is (= [1 2 3] [b c d]))))

(deftest namespaced-syms-syntax
  (let [{:a/syms [b c d] :or {d 3}} {'a/b 1 'a/c 2}]
    (is (= [1 2 3] [b c d]))))

;; CLJW: keywords-not-allowed-in-let-bindings skipped — requires eval + CompilerException
;; CLJW: namespaced-syms-only-allowed-in-map-destructuring skipped — requires eval
;; CLJW: or-doesnt-create-bindings skipped — requires eval

(require '[clojure.string :as s])
(deftest resolve-keyword-ns-alias-in-destructuring
  (let [{:keys [::s/x ::s/y ::s/z] :or {z 3}} {:clojure.string/x 1 :clojure.string/y 2}]
    (is (= [1 2 3] [x y z]))))

;; CLJW: quote-with-multiple-args skipped — requires eval + CompilerException + .getCause interop
;; CLJW: typehints-retained-destructuring skipped — requires should-not-reflect + .indexOf interop

;; CLJW-ADD: test runner invocation
(run-tests)
