;; Module load + instantiate overhead: load a small FFI module 100 times.
(dotimes [_ 100]
  (wasm/load "bench/wasm/ffi/fib.wasm"))

(println "loaded")
