;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; Author: Tom Faulhaber (upstream), adapted for CW

;; Upstream: clojure/test/clojure/test_clojure/pprint/test_pretty.clj
;; Upstream lines: 415
;; CLJW markers: 22
;; CLJW: Content-equivalent tests. Upstream uses cl-format, simple-dispatch,
;; code-dispatch, with-pprint-dispatch, write, pprint-logical-block etc.
;; which CW does not implement. Test names borrowed from upstream but test
;; content adapted to exercise CW's pprint builtin behavior.

(ns clojure.test-clojure.pprint
  ;; CLJW: removed (:refer-clojure :exclude [format]), clojure.string,
  ;; test-helper, test-clojure.pprint.test-helper, full clojure.pprint use.
  ;; CW pprint is a Zig builtin; cl-format/dispatch not available.
  (:use clojure.test)
  (:require [clojure.pprint :refer [pprint print-table]]))

;; CLJW: upstream uses (simple-tests ...) macro throughout.
;; CW uses standard (deftest ... (is ...)) since simple-tests is not available.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-test — basic pretty-print output
;;; CLJW: upstream tests cl-format with simple-dispatch and code-dispatch.
;;; CW tests basic pprint output for scalar values and simple forms.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-test
  ;; Scalar values
  (is (= "42\n" (with-out-str (pprint 42))))
  (is (= "nil\n" (with-out-str (pprint nil))))
  (is (= "true\n" (with-out-str (pprint true))))
  (is (= "false\n" (with-out-str (pprint false))))
  (is (= ":foo\n" (with-out-str (pprint :foo))))
  (is (= "\"hello\"\n" (with-out-str (pprint "hello"))))
  (is (= "foo\n" (with-out-str (pprint 'foo))))
  ;; CLJW: upstream tests write with :stream nil and dispatch.
  ;; CW tests pprint of quoted forms.
  (is (= "(defn foo [x y] (+ x y))\n"
         (with-out-str (pprint '(defn foo [x y] (+ x y))))))
  ;; CLJW: upstream tests var printing with #'Foo.
  ;; CW tests var printing.
  (is (= "#'clojure.core/+\n" (with-out-str (pprint #'clojure.core/+)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-reader-macro-test — reader macro forms through pprint
;;; CLJW: upstream tests with code-dispatch preserving #(), @@, '.
;;; CW pprint does not have code-dispatch, so reader macro forms print
;;; as expanded forms (quote → (quote ...), deref → (deref ...)).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-reader-macro-test
  ;; CLJW: CW expands reader macros, so 'foo becomes (quote foo)
  (is (= "(quote foo)\n" (with-out-str (pprint '(quote foo)))))
  ;; CLJW: deref form
  (is (= "(deref x)\n" (with-out-str (pprint '(deref x)))))
  ;; fn literal — read-string reads #(...) into (fn* [...] ...)
  ;; CLJW: CW expands #(first %) to (fn* [%1] (first %1))
  (is (= "(fn* [%1] (first %1))\n"
         (with-out-str (pprint (read-string "#(first %)"))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; print-length-tests — *print-length* interaction with pprint
;;; CLJW: upstream tests lists, vectors, sorted-sets, sorted-maps, int-arrays.
;;; CW tests lists, vectors, sets, maps (no sorted-set/sorted-map/int-array).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest print-length-tests
  ;; Lists
  (is (= "(a ...)\n" (with-out-str (binding [*print-length* 1] (pprint '(a b c d e f))))))
  (is (= "(a b ...)\n" (with-out-str (binding [*print-length* 2] (pprint '(a b c d e f))))))
  (is (= "(a b c d e f)\n" (with-out-str (binding [*print-length* 6] (pprint '(a b c d e f))))))
  (is (= "(a b c d e f)\n" (with-out-str (binding [*print-length* 8] (pprint '(a b c d e f))))))

  ;; Vectors
  (is (= "[1 ...]\n" (with-out-str (binding [*print-length* 1] (pprint [1 2 3 4 5 6])))))
  (is (= "[1 2 ...]\n" (with-out-str (binding [*print-length* 2] (pprint [1 2 3 4 5 6])))))
  (is (= "[1 2 3 4 5 6]\n" (with-out-str (binding [*print-length* 6] (pprint [1 2 3 4 5 6])))))
  (is (= "[1 2 3 4 5 6]\n" (with-out-str (binding [*print-length* 8] (pprint [1 2 3 4 5 6])))))

  ;; CLJW: upstream uses sorted-set for deterministic order.
  ;; CW sets have deterministic insertion order, so use small sets.
  ;; Sets
  (is (= "#{1 ...}\n" (with-out-str (binding [*print-length* 1] (pprint #{1 2 3 4 5 6})))))
  (is (= "#{1 2 ...}\n" (with-out-str (binding [*print-length* 2] (pprint #{1 2 3 4 5 6})))))

  ;; CLJW: upstream uses sorted-map for deterministic order.
  ;; CW maps have insertion order, so use small maps.
  ;; Maps
  (is (= "{:a 1, ...}\n" (with-out-str (binding [*print-length* 1] (pprint {:a 1 :b 2 :c 3})))))
  (is (= "{:a 1, :b 2, ...}\n" (with-out-str (binding [*print-length* 2] (pprint {:a 1 :b 2 :c 3})))))
  (is (= "{:a 1, :b 2, :c 3}\n" (with-out-str (binding [*print-length* 3] (pprint {:a 1 :b 2 :c 3})))))
  (is (= "{:a 1, :b 2, :c 3}\n" (with-out-str (binding [*print-length* 8] (pprint {:a 1 :b 2 :c 3}))))))

  ;; CLJW: upstream also tests int-array with print-length.
  ;; CW arrays are vectors, already tested above.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; print-level-tests — *print-level* interaction with pprint
;;; CLJW-ADD: upstream does not have explicit print-level tests for pprint,
;;; but CW supports it. Adding tests for completeness.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest print-level-tests
  (is (= "[1 [2 [3 #]]]\n"
         (with-out-str (binding [*print-level* 3] (pprint [1 [2 [3 [4 [5]]]]])))))
  (is (= "[1 [2 #]]\n"
         (with-out-str (binding [*print-level* 2] (pprint [1 [2 [3 [4 [5]]]]])))))
  (is (= "[1 #]\n"
         (with-out-str (binding [*print-level* 1] (pprint [1 [2 [3 [4 [5]]]]])))))
  (is (= "#\n"
         (with-out-str (binding [*print-level* 0] (pprint [1 [2 [3 [4 [5]]]]])))))
  ;; print-level with lists
  (is (= "(1 (2 #))\n"
         (with-out-str (binding [*print-level* 2] (pprint '(1 (2 (3 (4)))))))))
  ;; print-level with maps
  (is (= "{:a #}\n"
         (with-out-str (binding [*print-level* 1] (pprint {:a {:b {:c 1}}}))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-datastructures-tests — reference types through pprint
;;; CLJW: upstream tests future-filled/unfilled, promise-filled/unfilled,
;;; agent, atom, ref, delay-forced/unforced, defrecord, PersistentQueue.
;;; CW tests atom, delay (forced/unforced), agent.
;;; CW formats: #<atom ...>, #delay[...], #agent[...] (not JVM @hex format).
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-datastructures-tests
  ;; Atom
  (is (= "#<atom 42>\n" (with-out-str (pprint (atom 42)))))
  (is (= "#<atom {:x 1, :y 2}>\n" (with-out-str (pprint (atom {:x 1 :y 2})))))

  ;; Delay — forced
  ;; CLJW: CW uses #delay[value] format instead of #<Delay@hex: value>
  (let [d (delay (+ 1 2))]
    (force d)
    (is (= "#delay[3]\n" (with-out-str (pprint d)))))

  ;; Delay — unforced
  ;; CLJW: CW uses #delay[pending] instead of #<Delay@hex: :pending>
  (let [d (delay (+ 1 2))]
    (is (= "#delay[pending]\n" (with-out-str (pprint d)))))

  ;; Agent
  ;; CLJW: CW uses #agent[value] format instead of #<Agent@hex: value>
  (let [a (agent '(first second third))]
    (is (= "#agent[(first second third)]\n" (with-out-str (pprint a))))))

  ;; CLJW: future, promise, ref, defrecord, PersistentQueue not tested.
  ;; future/promise: CW has them but format differs.
  ;; ref: CW does not implement STM refs.
  ;; PersistentQueue: CW does not have clojure.lang.PersistentQueue/EMPTY.

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-wrapping-test — multi-line wrapping behavior
;;; CLJW-ADD: tests CW-specific wrapping at 72-column right margin.
;;; Upstream tests wrapping with *print-right-margin* binding.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-wrapping-test
  ;; Short collections stay on one line
  (is (= "[1 2 3]\n" (with-out-str (pprint [1 2 3]))))
  (is (= "(a b c)\n" (with-out-str (pprint '(a b c)))))
  (is (= "{:a 1, :b 2}\n" (with-out-str (pprint {:a 1 :b 2}))))
  (is (= "#{1 2 3}\n" (with-out-str (pprint #{1 2 3}))))

  ;; Long vector wraps to multiple lines (default 72 col margin)
  ;; CLJW: 50-element vector exceeds 72 columns, wraps with 1-space indent after [
  (let [result (with-out-str (pprint (vec (range 50))))]
    (is (.contains result "\n") "Long vector should wrap")
    (is (.startsWith result "[0") "Should start with [0")
    (is (.endsWith result "49]\n") "Should end with 49]"))

  ;; Long list wraps
  ;; CLJW: 20-element list is under 72 cols, stays on one line
  (is (= "(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19)\n"
         (with-out-str (pprint (range 20))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-empty-collections-test — empty collections
;;; CLJW-ADD: verify pprint handles empty collections correctly.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-empty-collections-test
  (is (= "[]\n" (with-out-str (pprint []))))
  (is (= "()\n" (with-out-str (pprint '()))))
  (is (= "{}\n" (with-out-str (pprint {}))))
  (is (= "#{}\n" (with-out-str (pprint #{})))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-strings-test — string values through pprint
;;; CLJW-ADD: verify pprint correctly quotes and escapes strings.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-strings-test
  (is (= "\"hello\"\n" (with-out-str (pprint "hello"))))
  (is (= "\"hello\\nworld\"\n" (with-out-str (pprint "hello\nworld"))))
  (is (= "\"tab\\there\"\n" (with-out-str (pprint "tab\there"))))
  (is (= "\"\"\n" (with-out-str (pprint "")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-nested-test — nested structures
;;; CLJW-ADD: verify pprint handles nested structures correctly.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-nested-test
  ;; Nested map (short — single line)
  (is (= "{:a [1 2 3], :b {:c 4}}\n"
         (with-out-str (pprint {:a [1 2 3] :b {:c 4}}))))

  ;; Nested vector (short — single line)
  (is (= "[[1 2] [3 4] [5 6]]\n"
         (with-out-str (pprint [[1 2] [3 4] [5 6]]))))

  ;; Mixed types in collection
  (is (= "[1 \"two\" :three nil true]\n"
         (with-out-str (pprint [1 "two" :three nil true])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; print-table-test — print-table function
;;; CLJW: upstream does not have print-table tests in test_pretty.clj.
;;; CLJW-ADD: CW has print-table in clojure.pprint, testing it here.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest print-table-test
  ;; Basic print-table with auto-detected keys
  (let [result (with-out-str (print-table [{:a 1 :b 2} {:a 3 :b 4}]))]
    (is (.contains result "| :a | :b |"))
    (is (.contains result "|----+----|"))
    (is (.contains result "|  1 |  2 |"))
    (is (.contains result "|  3 |  4 |")))

  ;; print-table with explicit keys
  (let [result (with-out-str (print-table [:name :age]
                                          [{:name "Alice" :age 30}
                                           {:name "Bob" :age 25}]))]
    (is (.contains result ":name"))
    (is (.contains result ":age"))
    (is (.contains result "Alice"))
    (is (.contains result "Bob"))
    (is (.contains result "30"))
    (is (.contains result "25")))

  ;; print-table with wider columns
  (let [result (with-out-str (print-table [:name :city]
                                          [{:name "Charlie" :city "Kyoto"}]))]
    (is (.contains result "Charlie"))
    (is (.contains result "Kyoto")))

  ;; CLJW: print-table with empty rows returns nil (no output)
  (is (= "" (with-out-str (print-table [])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-special-values-test — special numeric and symbolic values
;;; CLJW-ADD: verify pprint handles special values.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-special-values-test
  ;; Special float values
  (is (= "##Inf\n" (with-out-str (pprint ##Inf))))
  (is (= "##-Inf\n" (with-out-str (pprint ##-Inf))))
  (is (= "##NaN\n" (with-out-str (pprint ##NaN))))

  ;; Ratios
  (is (= "1/3\n" (with-out-str (pprint 1/3))))
  (is (= "22/7\n" (with-out-str (pprint 22/7))))

  ;; BigDecimal
  (is (= "3.14M\n" (with-out-str (pprint 3.14M))))

  ;; BigInt
  (is (= "99999999999999999999N\n" (with-out-str (pprint 99999999999999999999N)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;; pprint-print-length-and-level-combined — combined *print-length* + *print-level*
;;; CLJW-ADD: verify interaction of both controls.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(deftest pprint-print-length-and-level-combined
  ;; Both print-length and print-level
  (is (= "[1 ...]\n"
         (with-out-str (binding [*print-length* 1 *print-level* 1]
                         (pprint [1 [2 [3]]])))))
  (is (= "[1 #]\n"
         (with-out-str (binding [*print-length* 3 *print-level* 1]
                         (pprint [1 [2 [3]]]))))))

(run-tests)
