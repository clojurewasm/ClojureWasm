;; FFI call overhead: 1M invocations of a trivial wasm add over the boundary.
;; :fuel 0 = unlimited — measure raw throughput, not the sandbox fuel budget
;; (the finite 1e9 default would trap partway through a long benchmark loop).
(def m (wasm/load "bench/wasm/ffi/add.wasm" {:fuel 0}))

(loop [i 0]
  (when (< i 1000000)
    (wasm/call m "add" i 1)
    (recur (inc i))))

(println 1000000)
