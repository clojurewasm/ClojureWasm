;; [CLJW-SEQ-PRED-ISEQ] + D-482: the collection predicates clj defines as
;; `(instance? <interface> x)` answer for a deftype / reify that DECLARES the
;; interface, through the declared interface's clj superinterface closure
;; (Indexed extends Counted, ISeq extends IPersistentCollection, ...), and a
;; routed method never claims an interface the type did not declare (a
;; Counted-only type's `count` is dispatched through IPersistentCollection, yet
;; the type is not a coll). Every expectation here is the JVM Clojure answer:
;; this file runs unchanged under `clojure -M` and under cljw.
(ns suites.interface-predicates-test
  (:require [clojure.test :refer [deftest is]]))

(deftype PredSeq []
  clojure.lang.ISeq
  (first [_] 1)
  (next [_] nil)
  (more [_] ())
  (cons [this o] (clojure.core/cons o this))
  (seq [this] this)
  (count [_] 1)
  (empty [_] ())
  (equiv [_ o] false))

(deftype PredCounted [] clojure.lang.Counted (count [_] 7))
(deftype PredIndexed [] clojure.lang.Indexed (nth [_ i] i) (nth [_ i d] i))
(deftype PredFn [] clojure.lang.IFn (invoke [_] 1))
(deftype PredReversible [] clojure.lang.Reversible (rseq [_] (list 1)))
(deftype PredSeqable [] clojure.lang.Seqable (seq [_] (list 1 2)))
(deftype PredVector [] clojure.lang.IPersistentVector (count [_] 0) (nth [_ i] i))
(deftype PredColl []
  clojure.lang.IPersistentCollection
  (count [_] 0)
  (cons [this o] this)
  (empty [this] this)
  (equiv [_ o] false))
(deftype PredMap [] clojure.lang.IPersistentMap (count [_] 0))
(deftype PredSequential [] clojure.lang.Sequential)

(deftest deftype-declared-interface-answers-its-predicate
  (is (true? (seq? (PredSeq.))))
  (is (true? (coll? (PredSeq.))))
  (is (true? (seqable? (PredSeq.))))
  (is (true? (counted? (PredCounted.))))
  (is (true? (indexed? (PredIndexed.))))
  (is (true? (ifn? (PredFn.))))
  (is (true? (reversible? (PredReversible.))))
  (is (true? (seqable? (PredSeqable.))))
  (is (true? (vector? (PredVector.))))
  (is (true? (coll? (PredColl.))))
  (is (true? (map? (PredMap.))))
  (is (true? (sequential? (PredSequential.)))))

(deftest superinterface-closure
  ;; Indexed extends Counted.
  (is (true? (counted? (PredIndexed.))))
  (is (true? (instance? clojure.lang.Counted (PredIndexed.))))
  ;; IPersistentVector extends Associative, Sequential, IPersistentStack,
  ;; Reversible and Indexed; Associative extends IPersistentCollection.
  (is (= [true true true true true true true false]
         (let [v (PredVector.)]
           [(sequential? v) (associative? v) (counted? v) (indexed? v)
            (reversible? v) (coll? v) (seqable? v) (ifn? v)])))
  ;; IPersistentMap extends Associative and Counted.
  (is (= [true true true false]
         (let [m (PredMap.)] [(counted? m) (coll? m) (associative? m) (sequential? m)])))
  ;; IPersistentCollection extends Seqable only.
  (is (= [true false false]
         (let [c (PredColl.)] [(seqable? c) (counted? c) (seq? c)]))))

(deftest undeclared-interfaces-stay-false
  ;; ISeq is not Counted and not Sequential.
  (is (false? (counted? (PredSeq.))))
  (is (false? (sequential? (PredSeq.))))
  ;; Counted and Indexed extend neither IPersistentCollection nor Seqable, even
  ;; though cljw dispatches their `count` through IPersistentCollection.
  (is (= [false false false]
         [(coll? (PredCounted.)) (seqable? (PredCounted.))
          (instance? clojure.lang.IPersistentCollection (PredCounted.))]))
  (is (= [false false] [(coll? (PredIndexed.)) (seqable? (PredIndexed.))]))
  (is (= [false false false]
         [(seq? (PredSeqable.)) (coll? (PredSeqable.)) (counted? (PredSeqable.))]))
  (is (false? (ifn? (PredSeq.))))
  (is (false? (vector? (PredIndexed.)))))

(deftest reify-declared-interface-answers-its-predicate
  (is (true? (seq? (reify clojure.lang.ISeq
                     (first [_] 1) (next [_] nil) (more [_] ())
                     (cons [this o] nil) (seq [this] this) (count [_] 1)
                     (empty [_] ()) (equiv [_ o] false)))))
  (is (true? (counted? (reify clojure.lang.Counted (count [_] 3)))))
  (is (false? (coll? (reify clojure.lang.Counted (count [_] 3)))))
  (is (true? (ifn? (reify clojure.lang.IFn (invoke [_] 1)))))
  (is (true? (indexed? (reify clojure.lang.Indexed (nth [_ i] i) (nth [_ i d] i)))))
  (is (true? (counted? (reify clojure.lang.Indexed (nth [_ i] i) (nth [_ i d] i)))))
  (is (true? (reversible? (reify clojure.lang.Reversible (rseq [_] (list 1))))))
  (is (true? (sequential? (reify clojure.lang.Sequential))))
  (is (true? (vector? (reify clojure.lang.IPersistentVector (count [_] 0))))))

(deftest counted-follows-the-declared-interface
  (is (= 7 (count (PredCounted.))))
  (is (= 7 (bounded-count 2 (PredCounted.))))
  (is (= 2 (bounded-count 5 (PredSeqable.)))))

;; D-482: a Cons is an ASeq, not Counted. `(cons x nil)` is a PersistentList,
;; which is.
(deftest cons-is-not-counted
  (is (false? (counted? (cons 1 [2 3]))))
  (is (false? (counted? (list* 1 [2]))))
  (is (false? (counted? (conj (range 3) 99))))
  (is (false? (instance? clojure.lang.Counted (cons 1 [2 3]))))
  (is (true? (counted? (cons 1 nil))))
  (is (true? (counted? (list* 1 nil))))
  (is (= 2 (bounded-count 2 (cons 1 [2 3]))))
  (is (= 3 (count (cons 1 [2 3])))))

;; The transient interfaces extend Counted (and ITransientVector Indexed), so
;; the native answers follow the same closure.
(deftest transients-are-counted
  (is (= [true true true] [(counted? (transient [])) (counted? (transient {}))
                           (counted? (transient #{}))]))
  (is (true? (indexed? (transient []))))
  (is (false? (vector? (transient []))))
  (is (= 2 (bounded-count 1 (transient [1 2])))))

;; A map entry and the transients are invocable, so they are IFn; a list, a
;; seq and a queue are not. The class-level answer follows the same set.
(deftest ifn-follows-the-invocable-set
  (is (= [true true true true true]
         (mapv ifn? [(first {:a 1}) (subvec [1 2] 1) (transient []) (transient {})
                     (transient #{})])))
  (is (= [false false false]
         (mapv ifn? ['(1) (seq [1]) clojure.lang.PersistentQueue/EMPTY])))
  (is (= 1 ((first {:a 1}) 1)))
  (is (= 10 ((transient [10 20]) 0)))
  (is (true? (isa? (class (first {:a 1})) clojure.lang.IFn)))
  (is (true? (isa? (class (transient [])) clojure.lang.IFn)))
  (is (true? (isa? (class (subvec [1 2] 1)) clojure.lang.IFn)))
  (is (false? (isa? (class '(1)) clojure.lang.IFn))))
