(def m (wasm/load "bench/wasm/ffi/add.wasm" {:engine :interp :fuel 0}))
(println (wasm/call m "add" 0 0))
