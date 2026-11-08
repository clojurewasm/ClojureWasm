(def n 20000)
(defn burn [m]
  (loop [i 0 acc 0] (if (< i n) (recur (inc i) (wasm/call m "add" i 1)) acc)))
(defn ms [f] (let [t0 (System/nanoTime) _ (f) t1 (System/nanoTime)]
               (/ (double (- t1 t0)) 1000000.0)))
(defn ns-per [f] (/ (* (ms f) 1e6) n))

(def jit    (wasm/load "bench/wasm/ffi/add.wasm" {:engine :auto   :fuel 0}))
(def interp (wasm/load "bench/wasm/ffi/add.wasm" {:engine :interp :fuel 0}))

;; warm every path
(burn jit) (burn interp) @(future (burn jit)) @(future (burn interp))

(println (format "%-22s %10s" "cell" "ns/call"))
(println (format "%-22s %10.0f" "JIT    main thread"   (ns-per #(burn jit))))
(println (format "%-22s %10.0f" "JIT    worker thread" (ns-per #(deref (future (burn jit))))))
(println (format "%-22s %10.0f" "interp main thread"   (ns-per #(burn interp))))
(println (format "%-22s %10.0f" "interp worker thread" (ns-per #(deref (future (burn interp))))))
