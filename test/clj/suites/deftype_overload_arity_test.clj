;; D-530: merge same-name method arities across interface sections.
(ns suites.deftype-overload-arity-test
  (:require [clojure.test :refer [deftest is]]))

(deftype OverloadOne [v]
  clojure.lang.Seqable
  (seq [_] (list :one v))
  clojure.lang.Sorted
  (seq [_ ascending] (list :two v ascending)))

(deftype OverloadPaths [v]
  clojure.lang.Seqable
  ;; Both Java interface methods return ISeq, so the arity fixture must too.
  (seq [_] (list :arity-1))
  clojure.lang.Sorted
  (seq [_ asc] (list :arity-2 asc)))

(defrecord OverloadRecord [v]
  clojure.lang.Seqable
  (seq [_] (list :r1 v))
  clojure.lang.Sorted
  (seq [_ ascending] (list :r2 ascending)))

(deftype OverloadLookup [m]
  clojure.lang.ILookup
  (valAt [_ k] (get m k))
  (valAt [_ k nf] (get m k nf)))

(deftest deftype-seq-overload
  (let [t (OverloadOne. 42)]
    (is (= ['(:one 42) '(:two 42 true)] [(seq t) (. t seq true)]))))

(deftest deftype-seq-both-paths
  (let [t (OverloadPaths. 0)]
    (is (= ['(:arity-1) '(:arity-2 false) '(:arity-2 true)]
           [(seq t) (.seq t false) (. t seq true)]))))

(deftest defrecord-seq-overload
  (let [r (OverloadRecord. 7)]
    (is (= ['(:r1 7) '(:r2 false)] [(seq r) (. r seq false)]))))

(deftest within-section-multi-arity
  (let [l (OverloadLookup. {:a 1})]
    (is (= [1 99] [(.valAt l :a) (.valAt l :z 99)]))))

(deftest reify-seq-overload
  (let [r (reify clojure.lang.Seqable
            (seq [_] (list :a1))
            clojure.lang.Sorted
            (seq [_ asc] (list :a2 asc)))]
    (is (= ['(:a1) '(:a2 true)] [(. r seq) (. r seq true)]))))

(deftype OverloadInvalid []
  clojure.lang.Seqable
  (seq [_] :invalid)
  clojure.lang.Sorted
  (seq [_ asc] (list :valid asc)))

(deftest seq-return-contract-follows-arity-selection
  (let [t (OverloadInvalid.)]
    (is (thrown? ClassCastException (seq t)))
    (is (= '(:valid true) (.seq t true)))))
