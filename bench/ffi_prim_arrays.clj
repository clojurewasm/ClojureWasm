;; SPDX-License-Identifier: EPL-2.0
;; Kanban CLJW-FFI-PRIM-ARRAY-BYTES (ADR-0204): what a 1000-element f64 dot
;; costs through cljw.ffi, call only versus building its arguments.
;;
;;   cc -shared -fPIC -O2 -o /tmp/libdot.so test/e2e/fixtures/ffi/ffi_fixture.c
;;   cljw bench/ffi_prim_arrays.clj /tmp/libdot.so
;;
;; Prints microseconds per call, best of 5 runs. `:pointer` passes a
;; double-array's storage (only where arrays are typed); `:bytes` packs the
;; doubles into a byte array first, the only route before ADR-0204.
(require '[cljw.ffi :as ffi])

(def lib (ffi/open (first *command-line-args*)))
(def n 1000)
(def xs (vec (range n)))

(defn- best-us [iters f]
  (apply min (for [_ (range 5)]
               (let [t0 (System/nanoTime)]
                 (dotimes [_ iters] (f))
                 (/ (- (System/nanoTime) t0) 1000.0 iters)))))

(defn- f64s->bytes [ds]
  (byte-array
   (mapcat (fn [d] (let [b (Double/doubleToRawLongBits d)]
                     (for [i (range 8)] (unchecked-byte (bit-shift-right b (* 8 i))))))
           ds)))

(def dot-bytes (ffi/function lib "dot" [:bytes :bytes :long] :double))
(let [b (f64s->bytes xs)]
  (println "bytes-call-only-us" (best-us 2000 #(dot-bytes b b n)))
  (println "bytes-pack-and-call-us" (best-us 5 #(let [b (f64s->bytes xs)] (dot-bytes b b n)))))

(when (try (ffi/function lib "dot" [:pointer :pointer :long] :double)
           ((ffi/function lib "dot" [:pointer :pointer :long] :double) (double-array 1) (double-array 1) 1)
           true
           (catch Exception _ false))
  (let [dot (ffi/function lib "dot" [:pointer :pointer :long] :double)
        a (double-array xs)]
    (println "pointer-call-only-us" (best-us 2000 #(dot a a n)))
    (println "pointer-build-and-call-us" (best-us 2000 #(let [a (double-array xs)] (dot a a n))))
    (println "check" (dot a a n) (reduce + (map * xs xs)))))

(println "clojure-dot-us" (best-us 20 #(reduce + (map * xs xs))))
