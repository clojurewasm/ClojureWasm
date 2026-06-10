;; Modulo-heavy recursion in wasm: gcd(1071,462) called 1000000 times over FFI
;; (gcd is shallow, so the count is high to reach a stable ~0.7s timing).
(def m (wasm/load "bench/wasm/ffi/gcd.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0 result 0]
  (if (< i 1000000)
    (recur (inc i) (wasm/call m "gcd" 1071 462))
    (println result)))
