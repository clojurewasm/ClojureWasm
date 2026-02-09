;; Upstream: clojure/test/clojure/test_clojure/logic.clj
;; Upstream lines: 212
;; CLJW markers: 6

;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this distribution.

; Author: Frantisek Sodomka

;;
;;  Created 1/29/2009

(ns clojure.test-clojure.logic
  (:use clojure.test)) ;; CLJW: removed clojure.test-helper dependency

;; CLJW-ADD: exception helper (upstream from clojure.test-helper)
(defn exception [] (throw "test exception — should not be reached"))

;; *** Tests ***

(deftest test-if
  ; true/false/nil
  (are [x y] (= x y)
    (if true :t) :t
    (if true :t :f) :t
    (if true :t (exception)) :t

    (if false :t) nil
    (if false :t :f) :f
    (if false (exception) :f) :f

    (if nil :t) nil
    (if nil :t :f) :f
    (if nil (exception) :f) :f)

  ;; CLJW: removed JVM type casts (byte, short, int, long, bigint, float, double, bigdec),
  ;;       Ratio (0/2), into-array, java.util.Date
  ; zero/empty is true
  (are [x] (= (if x :t :f) :t)
    0
    0.0

    ""
    #""
    (symbol "")

    ()
    []
    {}
    #{})

  ;; CLJW: removed JVM type casts, Ratio (2/3), into-array, java.util.Date
  ; anything except nil/false is true
  (are [x]  (= (if x :t :f) :t)
    2
    2.0

    \a
    "abc"
    #"a*b"
    'abc
    :kw

    '(1 2)
    [1 2]
    {:a 1 :b 2}
    #{1 2}))

(deftest test-nil-punning
  (are [x y]  (= (if x :no :yes) y)
    (first []) :yes
    (next [1]) :yes
    (rest [1]) :no

    (butlast [1]) :yes

    (seq nil) :yes
    (seq []) :yes

    (sequence nil) :no
    (sequence []) :no

    (lazy-seq nil) :no
    (lazy-seq []) :no

    (filter #(> % 10) [1 2 3]) :no
    (map identity []) :no
    (apply concat []) :no

    (concat) :no
    (concat []) :no

    (reverse nil) :no
    (reverse []) :no

    (sort nil) :no
    (sort []) :no))

(deftest test-and
  (are [x y] (= x y)
    (and) true
    (and true) true
    (and nil) nil
    (and false) false

    (and true nil) nil
    (and true false) false

    (and 1 true :kw 'abc "abc") "abc"

    (and 1 true :kw nil 'abc "abc") nil
    (and 1 true :kw nil (exception) 'abc "abc") nil

    (and 1 true :kw 'abc "abc" false) false
    (and 1 true :kw 'abc "abc" false (exception)) false))

(deftest test-or
  (are [x y] (= x y)
    (or) nil
    (or true) true
    (or nil) nil
    (or false) false

    (or nil false true) true
    (or nil false 1 2) 1
    (or nil false "abc" :kw) "abc"

    (or false nil) nil
    (or nil false) false
    (or nil nil nil false) false

    (or nil true false) true
    (or nil true (exception) false) true
    (or nil false "abc" (exception)) "abc"))

(deftest test-not
;  (is (thrown? IllegalArgumentException (not)))
  (are [x] (= (not x) true)
    nil
    false)
  ;; CLJW: removed JVM type casts, Ratio (0/2, 2/3), into-array, java.util.Date
  (are [x]  (= (not x) false)
    true

      ; numbers
    0
    0.0
    42
    1.2

      ; characters
    \space
    \tab
    \a

      ; strings
    ""
    "abc"

      ; regexes
    #""
    #"a*b"

      ; symbols
    (symbol "")
    'abc

      ; keywords
    :kw

      ; collections
    ()
    '(1 2)
    []
    [1 2]
    {}
    {:a 1 :b 2}
    #{}
    #{1 2}))

(deftest test-some?
  (are [expected x] (= expected (some? x))
    false nil
    true false
    true 0
    true "abc"
    true []))

;; CLJW-ADD: test runner invocation
(run-tests)
