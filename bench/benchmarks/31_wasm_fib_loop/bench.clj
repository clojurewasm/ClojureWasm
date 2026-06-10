;; Iterative counterpart to wasm_fib: fib_loop(20) called 100000 times over FFI
;; (iterative, so the count is high to reach a stable ~0.2s timing).
(def m (wasm/load "bench/wasm/ffi/fib_loop.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 100000)
    (recur (inc i) (wasm/call m "fib_loop" 20))
    (println result)))
