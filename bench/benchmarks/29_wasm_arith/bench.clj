;; Tight loop in wasm with a 64-bit result: arith_loop(1M) run 10 times over FFI.
(def m (wasm/load "bench/wasm/ffi/arith.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 10)
    (recur (inc i) (wasm/call m "arith_loop" 1000000))
    (println result)))
