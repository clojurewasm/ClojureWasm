(require '[cljw.wasm :as wasm])

(def wmod (wasm/load "src/wasm/testdata/01_add.wasm"))
(def add (wasm/fn wmod "add"))

;; Call wasm add function 1M times
(loop [i 0]
  (when (< i 1000000)
    (add i 1)
    (recur (inc i))))

(println 1000000)
