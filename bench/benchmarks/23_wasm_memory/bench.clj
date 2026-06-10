;; Wasm linear-memory throughput: 100K store/load cycles over the FFI.
(def m (wasm/load "bench/wasm/ffi/memory.wasm" {:fuel 0}))  ; :fuel 0 = unlimited (benchmark)

(loop [i 0]
  (when (< i 100000)
    (wasm/call m "store" (* (rem i 1024) 4) i)  ; write at offset (i % 1024) * 4
    (wasm/call m "load" (* (rem i 1024) 4))     ; read back
    (recur (inc i))))

(println "done")
