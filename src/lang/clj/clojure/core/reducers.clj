;; SPDX-License-Identifier: EPL-2.0
;;
;;   Copyright (c) Rich Hickey. All rights reserved.
;;   The use and distribution terms for this software are covered by the
;;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php).
;;   By using this software in any fashion, you are agreeing to be bound by the
;;   terms of this license. You must not remove this notice, or any other, from
;;   this software.
;;
;;   clojure/core/reducers.clj — by Rich Hickey. Reproduced in ClojureWasm;
;;   redistributed under EPL-2.0 per EPL-1.0 §7. ClojureWasm changes (c) the
;;   ClojureWasm authors.

;; Two deliberate departures from the upstream file, both recorded:
;;
;; 1. `reducer` / `folder` / `Cat` reify **IReduce**, not
;;    `clojure.core.protocols/CollReduce`. `reduce` in ClojureWasm dispatches
;;    through IReduce (ADR-0007 Option β / D-069); CollReduce is declared but
;;    never consulted, so the upstream spelling would load fine and then fall
;;    through to the seq walk. Same protocol ClojureScript's port uses.
;;
;; 2. `fold` is **sequential** — see its docstring and AD-058. There is no
;;    ForkJoinPool (ADR-0093), so the work-splitting in `foldvec` and in `Cat`'s
;;    `coll-fold` recurses without forking. The value contract is unchanged: it
;;    is the same combine tree, evaluated in one thread. That is also the arm
;;    upstream itself takes for lists, ranges, sets and lazy seqs.
;;
;; Semantics come from the JVM file, the protocol and scheduler shape from the
;; ClojureScript one — ClojureScript's `mapcat` omits the `reduced` re-wrapping
;; and its `Cat`/`coll-fold` drops `combinef`, both of which would be silent
;; behaviour changes here.

(ns clojure.core.reducers
  (:refer-clojure :exclude [reduce map mapcat filter remove take take-while drop flatten cat])
  (:require [clojure.walk]))

(alias 'core 'clojure.core)

(defn reduce
  "Like core/reduce except:
     When init is not provided, (f) is used.
     Maps are reduced with reduce-kv"
  {:added "1.5"}
  ([f coll] (reduce f (f) coll))
  ([f init coll]
   (if (map? coll)
     (core/reduce-kv f init coll)
     (core/reduce f init coll))))

(defprotocol CollFold
  (coll-fold [coll n combinef reducef]))

(defn fold
  "Reduces a collection using a (potentially parallel) reduce-combine
  strategy. The collection is partitioned into groups of approximately n (default
  512), each of which is reduced with reducef (with a seed value obtained by
  calling (combinef) with no arguments). The results of these reductions are
  then reduced with combinef (default reducef). combinef must be associative,
  and, when called with no arguments, (combinef) must produce its identity
  element. These operations may be performed in parallel, but the results will
  preserve order.

  Note: Performing operations in parallel is currently not implemented."
  {:added "1.5"}
  ([reducef coll] (fold reducef reducef coll))
  ([combinef reducef coll] (fold 512 combinef reducef coll))
  ([n combinef reducef coll] (coll-fold coll n combinef reducef)))

(defn reducer
  "Given a reducible collection, and a transformation function xf,
  returns a reducible collection, where any supplied reducing
  fn will be transformed by xf. xf is a function of reducing fn to
  reducing fn."
  {:added "1.5"}
  ([coll xf]
   (reify
     IReduce
     (-reduce [_ f1] (core/reduce (xf f1) (f1) coll))
     (-reduce [_ f1 init] (core/reduce (xf f1) init coll)))))

(defn folder
  "Given a foldable collection, and a transformation function xf,
  returns a foldable collection, where any supplied reducing
  fn will be transformed by xf. xf is a function of reducing fn to
  reducing fn."
  {:added "1.5"}
  ([coll xf]
   (reify
     IReduce
     (-reduce [_ f1] (core/reduce (xf f1) (f1) coll))
     (-reduce [_ f1 init] (core/reduce (xf f1) init coll))

     CollFold
     (coll-fold [_ n combinef reducef]
       (coll-fold coll n combinef (xf reducef))))))

(defn- do-curried [name doc meta args body]
  (let [cargs (vec (butlast args))]
    `(defn ~name ~doc ~meta
       (~cargs (fn [x#] (~name ~@cargs x#)))
       (~args ~@body))))

(defmacro ^:private defcurried
  "Builds another arity of the fn that returns a fn awaiting the last
  param"
  [name doc meta args & body]
  (do-curried name doc meta args body))

(defn- do-rfn [f1 k fkv]
  `(fn
     ([] (~f1))
     ~(clojure.walk/postwalk
       #(if (sequential? %)
          ((if (vector? %) vec identity)
           (core/remove #{k} %))
          %)
       fkv)
     ~fkv))

(defmacro ^:private rfn
  "Builds 3-arity reducing fn given names of wrapped fn and key, and k/v impl."
  [[f1 k] fkv]
  (do-rfn f1 k fkv))

(defcurried map
  "Applies f to every value in the reduction of coll. Foldable."
  {:added "1.5"}
  [f coll]
  (folder coll
          (fn [f1]
            (rfn [f1 k]
                 ([ret k v] (f1 ret (f k v)))))))

(defcurried mapcat
  "Applies f to every value in the reduction of coll, concatenating the result
  colls of (f val). Foldable."
  {:added "1.5"}
  [f coll]
  (folder coll
          (fn [f1]
            ;; The re-wrap is load-bearing: `reduce` unwraps a `reduced` at the
            ;; IReduce boundary, so without it the inner reduction swallows the
            ;; early-exit signal and the outer one runs to completion.
            (let [f1 (fn
                       ([ret v] (let [x (f1 ret v)] (if (reduced? x) (reduced x) x)))
                       ([ret k v] (let [x (f1 ret k v)] (if (reduced? x) (reduced x) x))))]
              (rfn [f1 k]
                   ([ret k v] (reduce f1 ret (f k v))))))))

(defcurried filter
  "Retains values in the reduction of coll for which (pred val)
  returns logical true. Foldable."
  {:added "1.5"}
  [pred coll]
  (folder coll
          (fn [f1]
            (rfn [f1 k]
                 ([ret k v] (if (pred k v) (f1 ret k v) ret))))))

(defcurried remove
  "Removes values in the reduction of coll for which (pred val)
  returns logical true. Foldable."
  {:added "1.5"}
  [pred coll]
  (filter (complement pred) coll))

(defcurried flatten
  "Takes any nested combination of sequential things and returns their contents
  as a single, flat foldable collection."
  {:added "1.5"}
  [coll]
  (folder coll
          (fn [f1]
            (fn
              ([] (f1))
              ([ret v]
               (if (sequential? v)
                 (core/reduce f1 ret (flatten v))
                 (f1 ret v)))))))

(defcurried take-while
  "Ends the reduction of coll when (pred val) returns logical false."
  {:added "1.5"}
  [pred coll]
  (reducer coll
           (fn [f1]
             (rfn [f1 k]
                  ([ret k v] (if (pred k v) (f1 ret k v) (reduced ret)))))))

(defcurried take
  "Ends the reduction of coll after consuming n values."
  {:added "1.5"}
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
  {:added "1.5"}
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

(declare cat)

;; A concatenation of two reducible/foldable collections, kept as a tree so
;; `cat` is O(1) and a fold over the result can split at the seam.
(deftype Cat [cnt left right]
  clojure.lang.Counted
  (count [_] cnt)

  clojure.lang.Seqable
  (seq [_] (concat (seq left) (seq right)))

  IReduce
  (-reduce [this f1] (core/reduce f1 (f1) this))
  (-reduce [_ f1 init] (core/reduce f1 (core/reduce f1 init left) right))

  CollFold
  (coll-fold [_ n combinef reducef]
    (combinef (coll-fold left n combinef reducef)
              (coll-fold right n combinef reducef))))

(defn cat
  "A high-performance combining fn that yields the catenation of the
  reduced values. The result is reducible, foldable, seqable and
  counted, providing the identity collections are reducible, seqable
  and counted. The single argument version will build a combining fn
  with the supplied identity constructor. Tests for identity
  with (zero? (count x)). See also foldcat."
  {:added "1.5"}
  ([] (java.util.ArrayList.))
  ([ctor]
   (fn ([] (ctor))
     ([left right] (cat left right))))
  ([left right]
   (cond
     (zero? (count left)) right
     (zero? (count right)) left
     :else
     (Cat. (+ (count left) (count right)) left right))))

(defn append!
  ".adds x to acc and returns acc"
  {:added "1.5"}
  [acc x]
  (doto acc (.add x)))

(defn foldcat
  "Equivalent to (fold cat append! coll)"
  {:added "1.5"}
  [coll]
  (fold cat append! coll))

(defn monoid
  "Builds a combining fn out of the supplied operator and identity
  constructor. op must be associative and ctor called with no args
  must return an identity value for it."
  {:added "1.5"}
  [op ctor]
  (fn m
    ([] (ctor))
    ([a b] (op a b))))

;; The recursive halving upstream forks; here it recurses in one thread. The
;; combine tree — and therefore the value — is identical either way, which is
;; what AD-058 pins.
(defn- foldvec
  [v n combinef reducef]
  (cond
    (empty? v) (combinef)
    (<= (count v) n) (reduce reducef (combinef) v)
    :else
    (let [split (quot (count v) 2)
          v1 (subvec v 0 split)
          v2 (subvec v split (count v))]
      (combinef (foldvec v1 n combinef reducef)
                (foldvec v2 n combinef reducef)))))

(extend-protocol CollFold
  nil
  (coll-fold [coll n combinef reducef]
    (combinef))

  Object
  (coll-fold [coll n combinef reducef]
    ;; can't fold, single reduce
    (reduce reducef (combinef) coll))

  clojure.lang.IPersistentVector
  (coll-fold [v n combinef reducef]
    (foldvec v n combinef reducef)))
