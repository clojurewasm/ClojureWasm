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

;; CLJW: Object fallback delegates to __zig-reduce (CW Zig-level reduce)
;; directly to avoid circular calls when core/reduce dispatches through
;; coll-reduce for reducible collections (e.g. reducer/folder reify objects).
(extend-type nil CollReduce
             (coll-reduce
               ([coll f] (f))
               ([coll f val] val)))

(extend-type Object CollReduce
             (coll-reduce
               ([coll f] (seq-reduce coll f))
               ([coll f val] (__zig-reduce f val coll))))

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

;; CLJW: Redefine clojure.core/reduce to dispatch through CollReduce protocol
;; for reducible collections (reify objects from clojure.core.reducers).
;; Regular collections use __zig-reduce fast path. Reify objects (maps with
;; :__reify_type key) dispatch through coll-reduce to reach reify-specific impls.
(in-ns 'clojure.core)
(defn reduce
  ([f coll]
   (if (and (map? coll) (contains? coll :__reify_type))
     (clojure.core.protocols/coll-reduce coll f)
     (let [s (seq coll)]
       (if s
         (__zig-reduce f (first s) (next s))
         (f)))))
  ([f init coll]
   (if (and (map? coll) (contains? coll :__reify_type))
     (clojure.core.protocols/coll-reduce coll f init)
     (__zig-reduce f init coll))))
(in-ns 'clojure.core.protocols)
