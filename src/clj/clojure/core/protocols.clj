;   Copyright (c) Rich Hickey. All rights reserved.
;   The use and distribution terms for this software are covered by the
;   Eclipse Public License 1.0 (http://opensource.org/licenses/eclipse-1.0.php)
;   which can be found in the file epl-v10.html at the root of this distribution.
;   By using this software in any fashion, you are agreeing to be bound by
;   the terms of this license.
;   You must not remove this notice, or any other, from this software.

;; CLJW: ns form handled by bootstrap (loadProtocols sets namespace)
;; (ns clojure.core.protocols)

;; CLJW: Adapted from upstream clojure/core/protocols.clj
;; Java-specific types (IReduceInit, Iterable, ASeq, StringSeq, etc.)
;; replaced with CW type system. CollReduce Object delegates to
;; clojure.core/reduce builtin. InternalReduce uses naive-seq-reduce.
;; CLJW: Uses extend-type (special form) instead of extend-protocol (macro)
;; to avoid macro expansion issues during bootstrap.

(defprotocol CollReduce
  "Protocol for collection types that can implement reduce faster than
  first/next recursion. Called by clojure.core/reduce."
  (coll-reduce [coll f] [coll f val]))

(defprotocol InternalReduce
  "Protocol for concrete seq types that can reduce themselves
   faster than first/next recursion. Called by clojure.core/reduce."
  (internal-reduce [seq f start]))

(defn- naive-seq-reduce
  "Reduces a seq, ignoring any opportunities to switch to a more
  specialized implementation."
  [s f val]
  (loop [s (seq s)
         val val]
    (if s
      (let [ret (f val (first s))]
        (if (reduced? ret)
          @ret
          (recur (next s) ret)))
      val)))

(defn- seq-reduce
  ([coll f]
   (if-let [s (seq coll)]
     (naive-seq-reduce (next s) f (first s))
     (f)))
  ([coll f val]
   (let [s (seq coll)]
     (naive-seq-reduce s f val))))

;; CLJW: Object fallback delegates to CW builtin reduce which handles
;; all collection types efficiently (vectors, maps, sets, lazy-seqs, etc.)
(extend-type nil CollReduce
             (coll-reduce
               ([coll f] (f))
               ([coll f val] val)))

(extend-type Object CollReduce
             (coll-reduce
               ([coll f] (clojure.core/reduce f coll))
               ([coll f val] (clojure.core/reduce f val coll))))

(extend-type nil InternalReduce
             (internal-reduce
               [s f val]
               val))

(extend-type Object InternalReduce
             (internal-reduce
               [s f val]
               (naive-seq-reduce s f val)))

(defprotocol IKVReduce
  "Protocol for concrete associative types that can reduce themselves
   via a function of key and val faster than first/next recursion over map
   entries. Called by clojure.core/reduce-kv."
  (kv-reduce [amap f init]))

;; CLJW: Object fallback delegates to CW builtin reduce-kv
(extend-type nil IKVReduce
             (kv-reduce [amap f init] init))

(extend-type Object IKVReduce
             (kv-reduce [amap f init] (clojure.core/reduce-kv f init amap)))

(defprotocol Datafiable
  ;; CLJW: :extend-via-metadata not supported, omitted
  (datafy [o]))

(extend-type nil Datafiable
             (datafy [_] nil))

(extend-type Object Datafiable
             (datafy [x] x))

(defprotocol Navigable
  ;; CLJW: :extend-via-metadata not supported, omitted
  (nav [coll k v]))

(extend-type Object Navigable
             (nav [_ _ x] x))
