;; 1M crossings of the cljw -> wasm boundary, trivial add on the far side.
(def m (wasm/load "bench/wasm/ffi/add.wasm" {:fuel 0}))
(loop [i 0 acc 0]
  (if (< i 1000000)
    (recur (inc i) (wasm/call m "add" i 1))
    (println acc)))
