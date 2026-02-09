(require '[cljw.wasm :as wasm])

(def wmod (wasm/load-wasi "bench/wasm/tak.wasm"))
(def wasm-tak (wasm/fn wmod "tak"))

;; Call wasm tak(18,12,6) 10000 times
(loop [i 0 result 0]
  (if (< i 10000)
    (recur (inc i) (wasm-tak 18 12 6))
    (println result)))
