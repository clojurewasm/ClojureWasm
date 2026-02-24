(require '[cljw.wasm :as wasm])

;; Load + decode + instantiate a wasm module 100 times
(dotimes [_ 100]
  (wasm/load "src/app/wasm/testdata/02_fibonacci.wasm"))

(println "loaded")
