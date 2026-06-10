;; Deep recursion in wasm: tak(18,12,6) called 100 times over the FFI
;; (tak(18,12,6) fans out to ~63k wasm calls each, so 100 is already ~0.8s).
(def m (wasm/load "bench/wasm/ffi/tak.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 100)
    (recur (inc i) (wasm/call m "tak" 18 12 6))
    (println result)))
