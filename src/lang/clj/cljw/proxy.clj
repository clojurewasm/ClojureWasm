;; SPDX-License-Identifier: EPL-2.0
(ns cljw.proxy
  "Runtime support for `clojure.core/proxy` over the REGISTERED proxyable base
   classes (D-298). cljw has no JVM class hierarchy to extend, so `proxy` is a
   closed-per-build construct: each supported base has a deftype here that
   realizes its contract in the single-threaded wasm model, and
   `clojure.core/proxy` expands to a constructor call into this namespace
   (via clojure.core's proxy-base-registry). Adding a base = a deftype here +
   an entry in that registry; the `proxy` macro body never grows a branch.

   `.get`/`.set`/`.remove` interop dispatches to the protocol methods BELOW by
   method name (cljw resolves `.member` calls to a protocol method of that
   name), which is why the protocol lives in its own namespace that excludes the
   clashing clojure.core names."
  (:refer-clojure :exclude [get set remove]))

(defprotocol IThreadLocalCell
  "The java.lang.ThreadLocal surface cljw supports: a memoized one-slot cell."
  (get [this] "Current value; runs initialValue once on first get, then caches.")
  (set [this v] "Overwrite the cached value; returns v.")
  (remove [this] "Drop the cached value; the next get re-runs initialValue."))

(deftype ThreadLocalCell [^:unsynchronized-mutable present
                          ^:unsynchronized-mutable val
                          init-fn]
  IThreadLocalCell
  (get [this]
    (when-not present
      (set! val (init-fn))
      (set! present true))
    val)
  (set [this v] (set! val v) (set! present true) v)
  (remove [this] (set! val nil) (set! present false) nil))

(defn threadlocal-cell
  "Build a java.lang.ThreadLocal-equivalent cell whose initialValue is the
   0-arg `init-fn`. Single-thread wasm: one slot, no per-thread table (D-298)."
  [init-fn]
  (->ThreadLocalCell false nil init-fn))
