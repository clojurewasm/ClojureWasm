;; Compute-in-wasm: recursive fib(20) called 200 times over the FFI
;; (fib(20) fans out to ~13.5k wasm calls each, so 200 is already ~0.5s).
(def m (wasm/load "bench/wasm/ffi/fib.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 200)
    (recur (inc i) (wasm/call m "fib" 20))
    (println result)))
