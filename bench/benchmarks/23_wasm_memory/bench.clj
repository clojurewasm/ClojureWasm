(require '[cljw.wasm :as wasm])

(def wmod (wasm/load "src/wasm/testdata/03_memory.wasm"))
(def store-val (wasm/fn wmod "store"))
(def load-val (wasm/fn wmod "load"))

;; Write/read cycle: 100K iterations
(loop [i 0]
  (when (< i 100000)
    (store-val (* (rem i 1024) 4) i)  ; write at offset (i % 1024) * 4
    (load-val (* (rem i 1024) 4))     ; read back
    (recur (inc i))))

(println "done")
