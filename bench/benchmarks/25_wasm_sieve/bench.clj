;; Memory-heavy compute-in-wasm: sieve(65536) run 100 times over the FFI.
(def m (wasm/load "bench/wasm/ffi/sieve.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 100)
    (recur (inc i) (wasm/call m "sieve" 65536))
    (println result)))
