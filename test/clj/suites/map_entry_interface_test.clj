;; A deftype / reify may declare java.util.Map$Entry (core.logic's Pair does,
;; core/logic.clj:74). It is a protocol_remap onto cljw's IMapEntry
;; (-key/-val): (.getKey x) / (.getValue x) reach the type's own methods, and
;; key / val / map-entry? treat the instance as a map entry, as clj does
;; (clojure.core/key is (.getKey ^Map$Entry e)). The bare nested name after an
;; :import resolves too.
(ns suites.map-entry-interface-test
  (:require [clojure.test :refer [deftest is]])
  (:import (java.util Map$Entry)))

(deftype Pair [lhs rhs]
  clojure.lang.Counted
  (count [_] 2)
  java.util.Map$Entry
  (getKey [_] lhs)
  (getValue [_] rhs)
  Object
  (toString [_] (str "(" lhs " . " rhs ")")))

(deftype E [k v]
  Map$Entry
  (getKey [_] k)
  (getValue [_] v))

(deftest deftype-map-entry-methods
  (let [p (Pair. :a 1)]
    (is (= :a (.getKey p)))
    (is (= 1 (.getValue p)))
    (is (= "(:a . 1)" (str p)))))

(deftest key-val-reach-a-user-entry
  (let [p (Pair. :a 1)]
    (is (= :a (key p)))
    (is (= 1 (val p)))
    (is (true? (map-entry? p)))
    (is (true? (instance? java.util.Map$Entry p)))))

(deftest native-entries-unchanged
  (is (= [:x 9] [(key (first {:x 9})) (val (first {:x 9}))]))
  (is (thrown? ClassCastException (key [:k :v])))
  (is (false? (map-entry? (reify Object (toString [_] "x"))))))

(deftest reify-map-entry
  (let [r (reify java.util.Map$Entry (getKey [_] :rk) (getValue [_] :rv))]
    (is (= [:rk :rv :rk] [(key r) (val r) (.getKey r)]))))

(deftest bare-imported-name
  (let [e (E. 1 2)]
    (is (= [1 2] [(key e) (val e)]))))
