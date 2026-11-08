;; What Zig is good at, from Clojure: compile-time tables, @Vector SIMD, bit
;; builtins and std.crypto, through both FFI routes.
;; Run from this directory:  cljw zig_native.clj
;;
;; The wasm leg uses the committed kernel.wasm. The native leg needs the shared
;; library built from the same source (see kernel.zig) and is skipped without it.
(ns zig-native.demo
  (:require [cljw.ffi :as ffi]
            [clojure.java.io :as io]))

(def blake3-abc "6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
(def xs (mapv double (range 1 101)))
(def xs-dot (reduce + (map * xs xs)))   ; 338350.0

;; --- wasm: sandboxed, the guest owns its buffers ---------------------------
(def w (wasm/load "kernel.wasm" {:fuel 10000000}))
(assert (= [2 3 5 7919 104729] (mapv #(.nth_prime w %) [0 1 2 999 9999])))
(assert (= 8 (.popcount w 255)))
;; wasm i64 crosses exactly only within ±2^47 today (CLJW-WASM-I64-FULL-RANGE).
(assert (= (bit-shift-left 1 43) (.bitrev w (bit-shift-left 1 20))))
(let [fa (.f64_addr w)]
  (wasm/mem-write! w :f64 fa xs)
  (assert (= xs-dot (.dot w fa fa (count xs)))))
(let [ba (.byte_addr w)
      put! (fn [s] (wasm/mem-write! w :u8 ba (mapv int s)) (count s))]
  (assert (= 5 (.opcode w ba (put! "pow"))))
  (assert (= -1 (.opcode w ba (put! "mod"))))
  (let [out (+ ba 128)]
    (.blake3 w ba (put! "abc") out)
    (assert (= blake3-abc (apply str (map char (wasm/mem-read w :u8 out 64)))))))
(println "PASS zig-wasm")

;; --- native: cljw.ffi, full speed, no sandbox ------------------------------
(def lib-file (first (filter #(.exists (io/file %)) ["libkernel.so" "libkernel.dylib"])))

(defn f64s->bytes
  "Little-endian f64 bytes for a :bytes argument."
  [ds]
  (byte-array (mapcat (fn [d] (let [b (Double/doubleToRawLongBits (double d))]
                                (map #(unchecked-byte (bit-shift-right b (* 8 %))) (range 8))))
                      ds)))

(if lib-file
  (let [lib      (ffi/open (str "./" lib-file))
        libc     (ffi/open (if (= lib-file "libkernel.dylib") "libSystem.dylib" "libc.so.6"))
        malloc   (ffi/function libc "malloc" [:long] :pointer)
        free     (ffi/function libc "free" [:pointer] :void)
        nth-prime (ffi/function lib "nth_prime" [:int] :int)
        opcode   (ffi/function lib "opcode" [:string :long] :int)
        dot      (ffi/function lib "dot" [:bytes :bytes :long] :double)
        popcount (ffi/function lib "popcount" [:long] :int)
        bitrev   (ffi/function lib "bitrev" [:long] :long)
        blake3*  (ffi/function lib "blake3" [:string :long :pointer] :void)
        blake3   (fn [s] (let [out (malloc 65)]
                           (try (blake3* s (count s) out) (ffi/string out)
                                (finally (free out)))))]
    (assert (= [2 3 5 7919 104729] (mapv nth-prime [0 1 2 999 9999])))
    (assert (= {"add" 1 "pow" 5 "mod" -1}
               (into {} (map (juxt identity #(opcode % (count %)))) ["add" "pow" "mod"])))
    (let [b (f64s->bytes xs)] (assert (= xs-dot (dot b b (count xs)))))
    (assert (= 8 (popcount 255)))
    (assert (= Long/MIN_VALUE (bitrev 1)))   ; the full 64 bits cross the C ABI
    (assert (= blake3-abc (blake3 "abc")))
    (ffi/close lib)
    (println "PASS zig-native"))
  (println "SKIP zig-native (libkernel not built; see kernel.zig)"))

(println "DONE")
