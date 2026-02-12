;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: ns form handled by bootstrap (loadReducers sets namespace)
;; (ns clojure.core.reducers
;;   (:refer-clojure :exclude [reduce map mapcat filter remove take take-while drop flatten cat])
;;   (:require [clojure.walk :as walk]))

;; CLJW: alias core manually since we shadow some names
;; (alias 'core 'clojure.core) — not needed, we use clojure.core/ prefix

;; CLJW: ForkJoin replaced with sequential execution
;; pool, fjtask, fjinvoke, fjfork, fjjoin are CW stubs

(def pool nil) ;; CLJW: no ForkJoinPool

(defn fjtask [f] f) ;; CLJW: identity — no ForkJoinTask wrapping

(defn- fjinvoke [f] (f)) ;; CLJW: sequential — just call f

(defn- fjfork [task] task) ;; CLJW: no-op — sequential

(defn- fjjoin [task] (task)) ;; CLJW: sequential — just call task

(defn reduce
  "Like core/reduce except:
     When init is not provided, (f) is used.
     Maps are reduced with reduce-kv"
  ([f coll] (reduce f (f) coll))
  ([f init coll]
   (if (map? coll)
     (clojure.core.protocols/kv-reduce coll f init)
     (clojure.core.protocols/coll-reduce coll f init))))

(defprotocol CollFold
  (coll-fold [coll n combinef reducef]))

(defn fold
  "Reduces a collection using a (potentially parallel) reduce-combine
  strategy. The collection is partitioned into groups of approximately
  n (default 512), each of which is reduced with reducef (with a seed
  value obtained by calling (combinef) with no arguments). The results
  of these reductions are then reduced with combinef (default
  reducef). combinef must be associative, and, when called with no
  arguments, (combinef) must produce its identity element. These
  operations may be performed in parallel, but the results will
  preserve order."
  ([reducef coll] (fold reducef reducef coll))
  ([combinef reducef coll] (fold 512 combinef reducef coll))
  ([n combinef reducef coll]
   (coll-fold coll n combinef reducef)))

(defn monoid
  "Builds a combining fn out of the supplied operator and identity
  constructor. op must be associative and ctor called with no args
  must return an identity value for it."
  [op ctor]
  (fn m
    ([] (ctor))
    ([a b] (op a b))))

(defn reducer
  "Given a reducible collection, and a transformation function xf,
  returns a reducible collection, where any supplied reducing
  fn will be transformed by xf. xf is a function of reducing fn to
  reducing fn."
  [coll xf]
  (reify
    clojure.core.protocols/CollReduce
    (coll-reduce
      ([this f1] (clojure.core.protocols/coll-reduce this f1 (f1)))
      ([_ f1 init] (clojure.core.protocols/coll-reduce coll (xf f1) init)))))

(defn folder
  "Given a foldable collection, and a transformation function xf,
  returns a foldable collection, where any supplied reducing
  fn will be transformed by xf. xf is a function of reducing fn to
  reducing fn."
  [coll xf]
  (reify
    clojure.core.protocols/CollReduce
    (coll-reduce
      ([_ f1] (clojure.core.protocols/coll-reduce coll (xf f1) (f1)))
      ([_ f1 init] (clojure.core.protocols/coll-reduce coll (xf f1) init)))

    CollFold
    (coll-fold [_ n combinef reducef]
      (coll-fold coll n combinef (xf reducef)))))

;; --- Curried function helpers ---

(defn- do-curried
  [name doc meta args body]
  (let [cargs (vec (butlast args))]
    `(defn ~name ~doc ~meta
       (~cargs (fn [x#] (~name ~@cargs x#)))
       (~args ~@body))))

(defmacro ^:private defcurried
  "Builds another arity of the fn that returns a fn awaiting the last param"
  [name doc meta args & body]
  (do-curried name doc meta args body))

(defn- do-rfn [f1 k fkv]
  `(fn
     ([] (~f1))
     ~(clojure.walk/postwalk
       #(if (sequential? %)
          ((if (vector? %) vec identity)
           (clojure.core/remove #{k} %))
          %)
       fkv)
     ~fkv))

(defmacro ^:private rfn
  "Builds 3-arity reducing fn given names of wrapped fn and key, and k/v impl."
  [[f1 k] fkv]
  (do-rfn f1 k fkv))

;; --- Transformation functions ---

(defcurried map
  "Applies f to every value in the reduction of coll. Foldable."
  {}
  [f coll]
  (folder coll
          (fn [f1]
            (rfn [f1 k]
              ([ret k v]
               (f1 ret (f k v)))))))

(defcurried mapcat
  "Applies f to every value in the reduction of coll, concatenating the result
  colls of (f val). Foldable."
  {}
  [f coll]
  (folder coll
          (fn [f1]
            (let [f1 (fn
                       ([ret v]
                        (let [x (f1 ret v)] (if (reduced? x) (reduced x) x)))
                       ([ret k v]
                        (let [x (f1 ret k v)] (if (reduced? x) (reduced x) x))))]
              (rfn [f1 k]
                ([ret k v]
                 (reduce f1 ret (f k v))))))))

(defcurried filter
  "Retains values in the reduction of coll for which (pred val)
  returns logical true. Foldable."
  {}
  [pred coll]
  (folder coll
          (fn [f1]
            (rfn [f1 k]
              ([ret k v]
               (if (pred k v)
                 (f1 ret k v)
                 ret))))))

(defcurried remove
  "Removes values in the reduction of coll for which (pred val)
  returns logical true. Foldable."
  {}
  [pred coll]
  (filter (complement pred) coll))

(defcurried flatten
  "Takes any nested combination of sequential things (lists, vectors,
  etc.) and returns their contents as a single, flat foldable
  collection."
  {}
  [coll]
  (folder coll
          (fn [f1]
            (fn
              ([] (f1))
              ([ret v]
               (if (sequential? v)
                 (clojure.core.protocols/coll-reduce (flatten v) f1 ret)
                 (f1 ret v)))))))

(defcurried take-while
  "Ends the reduction of coll when (pred val) returns logical false."
  {}
  [pred coll]
  (reducer coll
           (fn [f1]
             (rfn [f1 k]
               ([ret k v]
                (if (pred k v)
                  (f1 ret k v)
                  (reduced ret)))))))

(defcurried take
  "Ends the reduction of coll after consuming n values."
  {}
  [n coll]
  (reducer coll
           (fn [f1]
             (let [cnt (atom n)]
               (rfn [f1 k]
                 ([ret k v]
                  (swap! cnt dec)
                  (if (neg? @cnt)
                    (reduced ret)
                    (f1 ret k v))))))))

(defcurried drop
  "Elides the first n values from the reduction of coll."
  {}
  [n coll]
  (reducer coll
           (fn [f1]
             (let [cnt (atom n)]
               (rfn [f1 k]
                 ([ret k v]
                  (swap! cnt dec)
                  (if (neg? @cnt)
                    (f1 ret k v)
                    ret)))))))

;; --- Cat type ---
;; CLJW: Uses defrecord instead of deftype (deftype is skip in CW)
;; CLJW: Counted/Seqable interfaces replaced with protocol implementations

(defrecord Cat [cnt left right])

;; CLJW: Extend Cat with CollReduce and CollFold protocols
(extend-type Cat clojure.core.protocols/CollReduce
             (coll-reduce
               ([this f1] (clojure.core.protocols/coll-reduce this f1 (f1)))
               ([this f1 init]
                (clojure.core.protocols/coll-reduce
                 (:right this) f1
                 (clojure.core.protocols/coll-reduce (:left this) f1 init)))))

(extend-type Cat CollFold
             (coll-fold
               [this n combinef reducef]
               (fjinvoke
                (fn []
                  (let [rt (fjfork (fjtask #(coll-fold (:right this) n combinef reducef)))]
                    (combinef
                     (coll-fold (:left this) n combinef reducef)
                     (fjjoin rt)))))))

(defn cat
  "A high-performance combining fn that yields the catenation of the
  reduced values. The result is reducible, foldable, seqable and
  counted, providing the identity collections are reducible, seqable
  and counted. The single argument version will build a combining fn
  with the supplied identity constructor. Tests for identity
  with (zero? (count x)). See also foldcat."
  ([] []) ;; CLJW: use vector instead of ArrayList
  ([ctor]
   (fn
     ([] (ctor))
     ([left right] (cat left right))))
  ([left right]
   (cond
     (zero? (count left)) right
     (zero? (count right)) left
     :else
     (->Cat (+ (count left) (count right)) left right))))

(defn append!
  "Adds x to acc and returns acc"
  ;; CLJW: uses conj instead of .add on ArrayList
  [acc x]
  (conj acc x))

(defn foldcat
  "Equivalent to (fold cat append! coll)"
  [coll]
  (fold cat append! coll))

;; --- fold impls ---

(defn- foldvec
  [v n combinef reducef]
  (cond
    (empty? v) (combinef)
    (<= (count v) n) (reduce reducef (combinef) v)
    :else
    (let [split (quot (count v) 2)
          v1 (subvec v 0 split)
          v2 (subvec v split (count v))
          fc (fn [child] #(foldvec child n combinef reducef))]
      (fjinvoke
       #(let [f1 (fc v1)
              t2 (fjtask (fc v2))]
          (fjfork t2)
          (combinef (f1) (fjjoin t2)))))))

(extend-type nil CollFold
             (coll-fold
               [coll n combinef reducef]
               (combinef)))

(extend-type Object CollFold
             (coll-fold
               [coll n combinef reducef]
    ;; can't fold, single reduce
               (reduce reducef (combinef) coll)))

;; CLJW: Vector fold uses foldvec for divide-and-conquer
(extend-type Vector CollFold
             (coll-fold
               [v n combinef reducef]
               (foldvec v n combinef reducef)))
