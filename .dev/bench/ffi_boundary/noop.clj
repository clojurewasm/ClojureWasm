;; Startup + module load only.
(def m (wasm/load "bench/wasm/ffi/add.wasm" {:fuel 0}))
(println (wasm/call m "add" 0 0))
